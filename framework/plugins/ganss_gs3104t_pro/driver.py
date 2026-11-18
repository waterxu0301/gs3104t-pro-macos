"""GANSS GS3104T PRO keyboard driver plugin.

Protocol layer (protocol.py/runner.py) reused verbatim from the
yunjianj/GANSS_GS3104T_Pro reverse-engineering project — already
hardware-verified for lighting and keymap on the 2.4G short-packet
channel and the wired feature channel.

Transport mapping to framework conventions:
- Wired feature channel: report_id=0, 65B API buffer (0x00 + 64B payload).
- 2.4G short channel: report_id=0 output write 33B; input responses 32/33B.
"""
import json
import re
import sys
import time
from pathlib import Path

from framework.base_driver import BaseDeviceDriver
from framework.errors import ConfigError, TransferError
from framework.safety import load_shadow, save_shadow
from . import protocol as P
from . import web_protocol as W
from .runner import ProtocolError, execute

PLUGIN_DIR = Path(__file__).resolve().parent

PRODUCT_RE = re.compile(r'GS3104T', re.IGNORECASE)


def _model_ok(name):
    model = re.sub(r'[\s_-]', '', name or '').upper()
    return model in ('GS3104TPRO', 'HFDGS3104TPRO', 'GS3104TPRO2.4G')


class Driver(BaseDeviceDriver):
    plugin_id = 'ganss_gs3104t_pro'

    # ---- matching --------------------------------------------------------

    def match(self, hid_entry, manifest):
        # 2.4G/wired: FF60 vendor channel. Bluetooth: standard pages only
        # (config channel absent) — match as read-only display device.
        if hid_entry['usage_page'] == 0xFF60 and PRODUCT_RE.search(hid_entry['product_string']):
            return True
        if PRODUCT_RE.search(hid_entry['product_string']):
            # bluetooth/wired w/o FF60: accept but the driver marks it readonly
            return True
        return False

    def pick_endpoint(self, endpoints):
        """FF60 channels: prefer interface 3 (32B short) for wireless, and
        interface 4 (64B feature) is exposed as usb. Bluetooth mode has no
        FF60 channel — return readonly marker."""
        ff60 = [e for e in endpoints if e['usage_page'] == 0xFF60]
        if not ff60:
            return {'path': None, 'connection': 'bluetooth', 'readonly': True}
        by_if = {e['interface_number']: e for e in ff60}
        primary = by_if.get(3) or ff60[0]
        return {'path': primary['path'], 'connection': 'wireless' if 3 in by_if else 'usb'}

    # ---- lifecycle -------------------------------------------------------

    def probe(self, transport, connection):
        if connection == 'bluetooth':
            return {'name': 'GANSS GS3104T PRO', 'connection': 'bluetooth',
                    'readonly': True, 'online': True,
                    'note': '蓝牙模式：固件不暴露配置通道（配置仅经 2.4G 接收器），请插回接收器以修改设置'}
        return {'name': 'GANSS GS3104T PRO', 'connection': connection,
                'hint': '映射生效前请按 Fn+Tab 开启驱动自定义按键'}

    def _web_session(self, transport):
        """New-protocol session on the 64B feature endpoint (if4)."""
        # pick_endpoint returns the short channel (if3) as primary; the AA
        # protocol was observed answering on the 64B feature endpoint.
        return W.WebProtocolSession(transport)

    def probe_web_protocol(self, transport):
        """Returns device info dict / 'unsupported' / None (asleep)."""
        return self._web_session(transport).probe()

    def read_state(self, transport, connection):
        if connection == 'bluetooth':
            shadow = load_shadow(self.plugin_id, _default_shadow)
            return {'connection': 'bluetooth', 'shadow': shadow,
                    'online': True, 'sleeping': False, 'readonly': True,
                    'web_protocol': False, 'readback': 'none',
                    'note': '蓝牙模式只读；配置通道在 2.4G 接收器上'}
        shadow = load_shadow(self.plugin_id, _default_shadow)
        state = {'connection': connection, 'shadow': shadow,
                 'fn_tab_required': True}
        web = self.probe_web_protocol(transport)
        if isinstance(web, dict):
            state['web_protocol'] = True
            state['battery'] = web.get('battery_level')
            state['firmware_version'] = web.get('frame_version')
            state['readback'] = 'hardware'
        elif web == 'unsupported':
            state['web_protocol'] = False
            state['readback'] = 'none'
        else:
            state['web_protocol'] = None
            state['readback'] = 'none'
            state['note'] = '键盘可能休眠；新协议能力（媒体键/宏/回读）待唤醒后探测'
        return state

    # ---- config operations -------------------------------------------------

    def apply_config(self, transport, connection, module, patch):
        if connection == 'bluetooth':
            raise ConfigError('蓝牙模式无配置通道；请把键盘切换到 2.4G 或有线后再修改设置')
        if module == 'lighting':
            return self._apply_lighting(transport, connection, patch)
        if module == 'keymap':
            return self._apply_keymap(transport, connection, patch)
        if module == 'macro':
            return self._apply_macro(transport, connection, patch)
        if module == 'keymap_full':
            return self._apply_full_layer(transport, connection, patch)
        if module == 'keymap_multi':
            return self._apply_multi(transport, connection, patch)
        raise ConfigError(f'未知模块: {module}')

    def _apply_macro(self, transport, connection, patch):
        """Macro binding via the web protocol. patch: {slot:int, actions:[...]}. 
        Requires new firmware (web protocol); legacy firmware raises."""
        web = self.probe_web_protocol(transport)
        if web != 'unsupported' and not isinstance(web, dict):
            raise TransferError('键盘休眠或新协议不可用：请按任意键唤醒后重试')
        if web == 'unsupported':
            raise ConfigError('当前固件不支持宏下发（需新固件，官方网页驱动配套版本）')
        actions = patch.get('actions', [])
        slot = int(patch.get('slot', 0))
        block = W.encode_macro_events(actions)
        sess = self._web_session(transport)
        ok = sess.write_macro({slot: block})
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('macros', {})[str(slot)] = patch
        save_shadow(self.plugin_id, shadow)
        return {'completed': ok, 'verified': 'sent', 'experimental': True,
                'note': '宏指令已按官方网页驱动协议下发（实验性，请实际验证）'}

    def _apply_lighting(self, transport, connection, patch):
        plan = P.light_plan(connection=connection,
                            mode=patch.get('mode', 11),
                            brightness=patch.get('brightness', 5),
                            speed=patch.get('speed', 3),
                            color=patch.get('color', 'FFFFFF'),
                            colorful=patch.get('colorful', False),
                            direction=patch.get('direction', 0))
        completed = self._execute_with_wake(transport, plan)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow['lighting'] = patch
        save_shadow(self.plugin_id, shadow)
        return {'completed_steps': completed, 'verified': 'ack_only',
                'note': '指令已确认接收；请目视确认灯光效果'}

    def _apply_keymap(self, transport, connection, patch):
        source, target = patch.get('source'), patch.get('target')
        layer = patch.get('layer', 'normal')
        if not source or not target:
            raise ConfigError('keymap patch 需要 source/target')
        if target.startswith('macro:'):
            return self._apply_macro_binding(transport, connection, patch)
        # Frame/record decoupling: media keys and disabled keys ride the SAME
        # legacy short/feature channel, only the 4B record differs.
        # Hardware-verified: [3, usage_lo, usage_hi, 0] consumer record ACKed
        # over the 33B short channel on DSM24 firmware.
        plan = _keymap_plan_with_record(source, target, layer, connection)
        completed = self._execute_with_wake(transport, plan)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('keymap', {}).setdefault(layer, {})[source] = target
        save_shadow(self.plugin_id, shadow)
        return {'completed_steps': completed, 'verified': 'ack_only',
                'note': '若按键未生效，请检查 Fn+Tab 是否开启驱动自定义按键'}

    def _apply_macro_binding(self, transport, connection, patch):
        """Bind a macro slot to a key over the legacy channel: record
        [6, slot, 0, 0]. The macro content itself goes through web_protocol
        when supported (else stored locally as pending)."""
        source = patch['source']
        slot = int(patch['target'].split(':')[1] or 0)
        plan = _keymap_plan_with_record(source, f'macro:{slot}',
                                        patch.get('layer', 'normal'), connection)
        completed = self._execute_with_wake(transport, plan)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('keymap', {}).setdefault(
            patch.get('layer', 'normal'), {})[source] = patch['target']
        save_shadow(self.plugin_id, shadow)
        return {'completed_steps': completed, 'verified': 'ack_only',
                'note': '宏绑定记录已下发；宏内容定义请使用 device.apply module=macro'}

    def reset_default(self, transport, connection, scope, layer='normal'):
        if scope == 'layer':
            return self._restore_full_layer(transport, connection, layer)
        raise ConfigError('reset scope 支持 key/layer')
    def _apply_full_layer(self, transport, connection, patch):
        """整层下发：基于 shadow 里的映射构造 576B 表（普通层 04 11 / Fn 层 04 27）"""
        layer = patch.get('layer', 'normal')
        mappings = patch.get('mappings', {})
        table = self._build_layer_table(layer, mappings)
        plan = self._layer_plan(table, layer, connection)
        completed = self._execute_with_wake(transport, plan)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('keymap', {})[layer] = mappings
        save_shadow(self.plugin_id, shadow)
        return {'completed_steps': completed, 'verified': 'ack_only',
                'note': f'{layer} 层整表（576B/9 块）已下发'}

    def _apply_multi(self, transport, connection, patch):
        """模板批量映射：逐键短报文下发（2.4G 高效路径）"""
        layer = patch.get('layer', 'normal')
        mappings = patch.get('mappings', {})
        completed = 0
        for source, target in mappings.items():
            plan = _keymap_plan_with_record(source, target, layer, connection)
            completed += self._execute_with_wake(transport, plan)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('keymap', {}).setdefault(layer, {}).update(mappings)
        save_shadow(self.plugin_id, shadow)
        return {'completed_steps': completed, 'verified': 'ack_only',
                'note': f'模板批量映射 {len(mappings)} 键已下发'}

    def _restore_full_layer(self, transport, connection, layer):
        table = self._build_layer_table(layer, {})
        plan = self._layer_plan(table, layer, connection)
        completed = self._execute_with_wake(transport, plan)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('keymap', {})[layer] = {}
        save_shadow(self.plugin_id, shadow)
        return {'completed_steps': completed, 'verified': 'ack_only',
                'note': f'{layer} 层已恢复全默认'}

    def _build_layer_table(self, layer, mappings):
        table = bytearray(576)
        for source, target in mappings.items():
            if target in (None, '', 'default'):
                continue
            rec = _legacy_record(target)
            if rec is None:
                continue
            try:
                key = P.resolve_key(source)
            except Exception:
                continue
            idx = int(key['key_index'])
            table[idx*4:idx*4+4] = rec
        table[-2:] = b'\xaa\x55'
        return bytes(table)

    def _layer_plan(self, table, layer, connection):
        cmd = 0x27 if layer == 'fn' else 0x11
        plan = [P.Step('准备键位事务', 'feature', P.command(0x18), True),
                P.Step(f'选择{layer}层', 'feature', P.command(cmd, 9), True)]
        plan += [P.Step(f'键位块 {i//64+1}/9', 'feature', P.feature(table[i:i+64]))
                 for i in range(0, 576, 64)]
        plan += [P.Step('结束键位事务', 'feature', P.command(2), True),
                 P.Step('刷新键位', 'feature', P.command(0xF0), True)]
        return plan

    def _execute(self, transport, plan):
        try:
            return execute(plan, _TransportAdapter(transport), time.sleep)
        except ProtocolError as e:
            raise TransferError(str(e)) from e

    def _execute_with_wake(self, transport, plan, attempts=3):
        """Keyboard sleeps when idle; short-packet echo only flows while
        awake. Retry on separate opens — success requires the user to press
        any key if the device is fully asleep."""
        last_err = None
        for _ in range(attempts):
            try:
                return self._execute(transport, plan)
            except TransferError as e:
                last_err = e
                time.sleep(1.0)
        raise TransferError(
            f'{last_err}\n键盘可能休眠：请按任意键唤醒键盘后重试') from last_err

    # ---- frontend data ----------------------------------------------------

    def keys_list(self):
        km = json.loads((PLUGIN_DIR / 'data' / 'keymap.json').read_text(encoding='utf-8'))
        return [{'index': int(k['key_index']), 'name': k['name'], 'usage': k['code'],
                 'rect': [int(k['rect_left']), int(k['rect_top']),
                          int(k['rect_width']), int(k['rect_height'])]}
                for k in km]

    def media_keys_list(self):
        return [{'id': f'media:{k}', 'name': k} for k in W.CONSUMER_KEYS]

    # ---- profiles (multi-config + import/export) --------------------------

    def list_profiles(self):
        store = load_shadow(self.plugin_id, _default_profiles_store)
        return [{'name': n, 'keymap': v.get('keymap', {}), 'lighting': v.get('lighting', {})}
                for n, v in store.get('profiles', {}).items()]

    def save_profile(self, name, data):
        store = load_shadow(self.plugin_id, _default_profiles_store)
        store.setdefault('profiles', {})[name] = data
        save_shadow(self.plugin_id, store)
        return {'saved': name}

    def delete_profile(self, name):
        store = load_shadow(self.plugin_id, _default_profiles_store)
        store.get('profiles', {}).pop(name, None)
        save_shadow(self.plugin_id, store)
        return {'deleted': name}

    def export_profiles(self):
        return load_shadow(self.plugin_id, _default_profiles_store)

    def import_profiles(self, payload):
        if not isinstance(payload, dict) or 'profiles' not in payload:
            raise ConfigError('导入格式错误：需要 {"profiles": {...}}')
        merged = load_shadow(self.plugin_id, _default_profiles_store)
        merged.setdefault('profiles', {}).update(payload['profiles'])
        save_shadow(self.plugin_id, merged)
        return {'imported': len(payload['profiles'])}


def _default_profiles_store():
    return {'active': None, 'profiles': {
        '默认': {'keymap': {'normal': {}, 'fn': {}},
                 'lighting': {'mode': 11, 'brightness': 5, 'speed': 3,
                              'color': 'FFFFFF', 'colorful': False}}}}


def _default_shadow():
    return {'lighting': {'mode': 11, 'brightness': 5, 'speed': 3,
                         'color': 'FFFFFF', 'colorful': False},
            'keymap': {'normal': {}, 'fn': {}},
            'macros': {}, 'pending_sync': False}


def _legacy_record(target):
    """4B keymap record for the LEGACY channel (frame/record decoupled).
    Types verified against the official web driver's record semantics and
    ACK-tested on DSM24 firmware over the 33B short channel:
      default → [2,0,usage,0] restored by keymap_single_plan (caller handles)
      media:X → [3, usage&255, usage>>8, 0]  (Consumer Page 16-bit LE)
      disabled → [1, 0, 0, 0]  (mouse-type zero record = no action)
      KEY/combo → [2, modifier_mask, usage, 0]  (E0..E7 bitmask)
      macro:N → [6, N, 0, 0]
    """
    if target in (None, '', 'default'):
        return None
    if target == 'disabled':
        return bytes((1, 0, 0, 0))
    if target.startswith('media:'):
        usage = W.CONSUMER_KEYS[target[6:]]
        return bytes((3, usage & 0xFF, (usage >> 8) & 0xFF, 0))
    if target.startswith('macro:'):
        return bytes((6, int(target[6:]), 0, 0))
    # keyboard key / combo (legacy layout: mask in byte1, usage in byte2)
    mask, usage = 0, None
    for part in target.split('+'):
        part = part.strip()
        if part in W.MODIFIERS:
            mask |= W.MODIFIERS[part]
        else:
            try:
                usage = int(part, 0)
            except ValueError:
                usage = W._lookup_usage(part)
    if usage is None:
        raise ConfigError(f'{target} 缺少普通键')
    return bytes((2, mask, usage & 0xFF, 0))


def _keymap_plan_with_record(source, target, layer, connection):
    """Build a single-key plan on the legacy channel carrying an arbitrary
    4B record (media/disabled/macro), mirroring keymap_single_plan layout:
    short packet [03/0D, len=4, key_index, record×4] or wired 576B table."""
    key = P.resolve_key(source)
    if key['name'] == 'Fn':
        raise ConfigError('本版本保留 Fn 键的默认功能')
    record = _legacy_record(target)
    if record is None:
        return P.keymap_single_plan(source, target, layer=layer, connection=connection)
    if connection != 'wireless':
        raise ConfigError('媒体键/禁用/宏记录当前仅支持 2.4G 短报文通道；有线请使用整层配置')
    p = bytearray(33)
    p[1:4] = bytes((3 if layer == 'normal' else 0x0D, 4, int(key['key_index'])))
    p[4:8] = record
    return [P.Step(f'{layer} 层单键 {key["name"]} → {target}', 'short',
                   P.short_packet(p), True, 5)]


class _TransportAdapter:
    """Adapts framework HidTransport to the protocol runner's expectations
    (send_feature already includes the 0x00 report-ID byte in the legacy
    API; here the transport adds it, so payload excludes it)."""

    def __init__(self, transport):
        self.t = transport

    def send_feature(self, data):
        # legacy data[0] is report-ID 0; strip before passing to transport
        payload = bytes(data[1:]) if data[0] == 0 else bytes(data)
        self.t.send_feature(0, payload)

    def get_feature(self):
        try:
            raw = self.t.get_feature(0, 64)
        except OSError as e:
            # read error usually means the keyboard went to sleep mid-transaction;
            # raise ProtocolError so the wake-retry loop in _execute_with_wake kicks in
            raise ProtocolError(f'Feature 读取失败（设备可能休眠）: {e}') from e
        # normalize: 65B w/ leading zero or 64B bare
        if len(raw) == 65 and raw[0] == 0:
            return raw[1:]
        if len(raw) == 64:
            return raw
        raise TransferError(f'Feature 响应长度异常: {len(raw)}')

    def short_exchange(self, data):
        # legacy data includes leading report-ID 0x00; transport prepends it
        payload = bytes(data[1:]) if data[0] == 0 else bytes(data)
        self.t.write_output(0, payload)
        deadline = time.monotonic() + 0.4
        while time.monotonic() < deadline:
            got = self.t.poll_input(64, timeout_ms=max(1, int((deadline - time.monotonic()) * 1000)))
            if got is None:
                break
            _rid, resp = got
            # normalize a possible leading zero from unnumbered stacks
            if resp and resp[0] == 0 and len(resp) > 32:
                resp = resp[1:]
            if resp[:3] == payload[0:3]:
                return
        raise TimeoutError('未收到匹配的无线命令回显')
