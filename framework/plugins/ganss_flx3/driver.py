"""GANSS FLX3 mouse driver plugin."""
import threading
import time

from framework.base_driver import BaseDeviceDriver
from framework.errors import ConfigError, TransferError
from framework.safety import load_shadow, save_shadow
from . import protocol as P


class Driver(BaseDeviceDriver):
    plugin_id = 'ganss_flx3'
    numbered_reports = True  # transport flag for FLX3-style devices

    def __init__(self):
        self._seq = P.Seq()
        self._telemetry = {}
        self._lock = threading.Lock()

    # ---- matching -------------------------------------------------------

    def match(self, hid_entry, manifest):
        # PluginManager already AND-matched manifest rules (vid+pid+regex /
        # vid+regex+usage_page). Extra guard: skip keyboard-like pages.
        return hid_entry['usage_page'] >= 0xFF00 or hid_entry['usage_page'] in (0x01, 0x0C)

    def pick_endpoint(self, endpoints):
        ff = [e for e in endpoints if e['usage_page'] >= 0xFF00]
        if not ff:
            # fallback: first interface that exposes a generic collection
            ff = endpoints
        return {'path': ff[0]['path'], 'connection': 'wired'}

    # ---- lifecycle -------------------------------------------------------

    def probe(self, transport, connection):
        state = self._read_telemetry(transport)
        info = {'name': 'GANSS FLX3', 'connection': connection}
        if state:
            info['battery'] = state.get('batteryLevel')
            info['sensor'] = P.SENSORS.get(state.get('sensorType'), ('未知', 100, 0))[0]
            info['sensorType'] = state.get('sensorType')
            info['online'] = bool(state.get('linkStatus'))
        else:
            info['online'] = False
            info['note'] = '未收到 reportId=4 上报；移动鼠标唤醒'
        return info

    def _read_telemetry(self, transport, wait_ms=600):
        """Poll for the device's reportId=4 input report."""
        deadline = time.monotonic() + wait_ms / 1000
        while time.monotonic() < deadline:
            got = transport.poll_input(64, timeout_ms=100)
            if got is None:
                continue
            rid, payload = got
            parsed = P.parse_input_report(payload)
            if parsed:
                self._telemetry = parsed
                return parsed
        return None

    def read_state(self, transport, connection):
        shadow = load_shadow(self.plugin_id, _default_shadow)
        live = self._read_telemetry(transport, wait_ms=300)
        state = {
            'connection': connection,
            'shadow': shadow,
            'live': live or {},
            'online': bool(live and live.get('linkStatus')),
            'sleeping': not (live and live.get('linkStatus')),
            'battery': (live or {}).get('batteryLevel'),
            'sensorType': (live or {}).get('sensorType', P.DEFAULT_SENSOR),
            'maxReportRate': (live or {}).get('maxReportRate', P.DEFAULT_MAX_RATE),
        }
        return state

    # ---- command plumbing -------------------------------------------------

    def _send_cmd(self, transport, logical, max_attempts=3):
        """Send one command with official retry/backoff semantics:
        delay 100+attempt*50 ms, then check ACK status byte == 1."""
        for attempt in range(max_attempts):
            time.sleep((100 + attempt * 50) / 1000)
            buf = P.set_checksum(logical)
            transport.send_feature(P.REPORT_CMD, buf)
            ack = self._read_ack(transport)
            if ack:
                return ack
        raise TransferError(f'命令 0x{logical[0]:02X} 无 ACK（已重试 {max_attempts} 次）；'
                            '请移动鼠标唤醒设备后重试')

    def _read_ack(self, transport, wait_ms=400):
        deadline = time.monotonic() + wait_ms / 1000
        while time.monotonic() < deadline:
            got = transport.poll_input(64, timeout_ms=80)
            if got is None:
                continue
            rid, payload = got
            b = payload[1:] if payload and payload[0] in (4, 5, 6) else payload
            if len(b) >= 2 and b[0] == P.REPORT_CMD:
                return b
        return None

    def _ack_ok(self, ack):
        # status at index 1 of the ACK payload (getUint8(1) in WebHID terms,
        # where [0] is the report id we already stripped)
        return len(ack) >= 2 and ack[1] == 1

    def _cmd(self, transport, logical):
        ack = self._send_cmd(transport, logical)
        if not self._ack_ok(ack):
            raise TransferError(f'命令 0x{logical[0]:02X} 设备返回失败状态: {ack[1] if ack else None}')
        return ack

    # ---- config modules ----------------------------------------------------

    def apply_config(self, transport, connection, module, patch):
        fn = {'keymap': self._apply_keymap, 'dpi': self._apply_dpi,
              'dpi_color': self._apply_dpi_color, 'polling': self._apply_polling,
              'lod': self._apply_lod, 'lighting': self._apply_lighting,
              'power': self._apply_power, 'sensor': self._apply_sensor,
              'macro': self._apply_macro, 'factory_reset': self._apply_reset}
        if module not in fn:
            raise ConfigError(f'未知模块: {module}')
        return fn[module](transport, patch)

    def _apply_keymap(self, transport, patch):
        buttons = patch.get('buttons', {})
        logical = P.encode_keymap_packet(buttons, self._seq.next())
        self._cmd(transport, logical)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('keymap', {}).update(buttons)
        shadow['pending_sync'] = False
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack', 'note': '6键映射已写入并通过ACK校验'}

    def _apply_dpi(self, transport, patch):
        sensor = int(patch.get('sensorType', P.DEFAULT_SENSOR))
        live = self._telemetry or {}
        sensor = live.get('sensorType', sensor)
        logical = P.encode_dpi_packet(
            axis=patch.get('axis', 'x'),
            current_index=int(patch.get('currentLevel', 0)),
            enabled_mask=int(patch.get('enabledMask', 0x3F)),
            dpi_values=patch.get('dpiValues', [400, 800, 1600, 3200, 6400]),
            sensor_type=sensor,
            seq=self._seq.next())
        self._cmd(transport, logical)
        if patch.get('xyIndependent'):
            logical_y = P.encode_dpi_packet(
                axis='y', current_index=int(patch.get('currentLevelY', patch.get('currentLevel', 0))),
                enabled_mask=int(patch.get('enabledMask', 0x3F)),
                dpi_values=patch.get('dpiValuesY', patch.get('dpiValues', [])),
                sensor_type=sensor, seq=self._seq.next())
            self._cmd(transport, logical_y)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('dpi', {}).update(patch)
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack', 'sensor': P.SENSORS[sensor][0],
                'note': f'DPI 已写入（{P.SENSORS[sensor][0]} 步进{P.SENSORS[sensor][1]}）'}

    def _apply_dpi_color(self, transport, patch):
        logical = P.encode_dpi_color_packet(patch.get('colors', []), self._seq.next())
        self._cmd(transport, logical)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('dpiColor', {}).update(patch)
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack'}

    def _apply_polling(self, transport, patch):
        rate = int(patch['rate'])
        if rate not in P.POLLING_RATES:
            raise ConfigError(f'无效回报率代码: {rate}')
        self._cmd(transport, P.encode_polling_packet(rate, self._seq.next()))
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('performance', {})['pollingRate'] = rate
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack', 'rate': P.POLLING_RATES[rate]}

    def _apply_lod(self, transport, patch):
        self._cmd(transport, P.encode_lod_packet(int(patch['lod']), self._seq.next()))
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('performance', {})['liftOffDistance'] = patch['lod']
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack'}

    def _apply_lighting(self, transport, patch):
        self._cmd(transport, P.encode_light_packet(
            int(patch.get('mode', 0)), patch.get('color', '#409EFF'),
            int(patch.get('brightness', 4)), int(patch.get('speed', 3)),
            int(patch.get('direction', 0)), self._seq.next()))
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('lighting', {}).update(patch)
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack'}

    def _apply_power(self, transport, patch):
        self._cmd(transport, P.encode_power_packet(
            int(patch.get('sleepTime', 1)), patch.get('moveWakeup', True),
            patch.get('moveLighting', False), self._seq.next()))
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('power', {}).update(patch)
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack'}

    def _apply_sensor(self, transport, patch):
        self._cmd(transport, P.encode_sensor_packet(
            patch.get('angleSnap', False), patch.get('motionSync', True),
            patch.get('rippleControl', False), self._seq.next()))
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('sensor', {}).update(patch)
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack'}

    def _apply_macro(self, transport, patch):
        """patch: {buttonIndex, events:[...], executeType, repeatCount}"""
        button = int(patch.get('buttonIndex', 4))
        events = patch.get('events', [])
        buffer = P.encode_macro_events(events)
        buffer[2] = button
        # erase macro area
        self._cmd(transport, P.encode_macro_erase(self._seq.next()))
        time.sleep(0.1)
        for chunk in P.encode_macro_chunks(list(buffer), button):
            self._cmd(transport, chunk)
            time.sleep(0.12)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('macros', {})[str(button)] = patch
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack', 'note': '宏已擦除并分块下发'}

    def _apply_reset(self, transport, patch):
        self._cmd(transport, P.encode_reset_packet(self._seq.next()))
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow['pending_sync'] = False
        save_shadow(self.plugin_id, shadow)
        return {'verified': 'ack', 'note': '已恢复出厂设置（含宏区擦除）'}

    def reset_default(self, transport, connection, scope):
        return self._apply_reset(transport, {})

    # ---- frontend helpers ---------------------------------------------------

    def keys_list(self):
        return []  # mouse uses button indices; UI renders from manifest props


def _default_shadow():
    return {
        'keymap': {},
        'dpi': {'currentLevel': 2, 'enabledMask': 0x3F,
                'dpiValues': [400, 800, 1600, 3200, 6400]},
        'dpiColor': {'colors': ['#FF0000', '#0066FF', '#32AA70', '#F59C25',
                                 '#00DDE4', '#B500EC', '#FF6B6B', '#4ECDC4']},
        'performance': {'pollingRate': 1, 'liftOffDistance': 2},
        'power': {'sleepTime': 1, 'moveWakeup': True, 'moveLighting': False},
        'sensor': {'angleSnap': False, 'motionSync': True, 'rippleControl': False},
        'lighting': {'mode': 0, 'color': '#409EFF', 'brightness': 4, 'speed': 3},
        'macros': {},
        'pending_sync': False,
    }
