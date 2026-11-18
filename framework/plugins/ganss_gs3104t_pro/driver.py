"""GANSS GS3104T PRO keyboard driver plugin.

Protocol layer (protocol.py/runner.py) reused verbatim from the
yunjianj/GANSS_GS3104T_Pro reverse-engineering project — already
hardware-verified for lighting and keymap on the 2.4G short-packet
channel and the wired feature channel.

Transport mapping to framework conventions:
- Wired feature channel: report_id=0, 65B API buffer (0x00 + 64B payload).
- 2.4G short channel: report_id=0 output write 33B; input responses 32/33B.
"""
import re
import sys
import time
from pathlib import Path

from framework.base_driver import BaseDeviceDriver
from framework.errors import ConfigError, TransferError
from framework.safety import load_shadow, save_shadow
from . import protocol as P
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
        # manifest already AND-matched vid/pid/product_regex in PluginManager;
        # add the usage_page vendor-channel check here.
        return (hid_entry['usage_page'] == 0xFF60 and
                PRODUCT_RE.search(hid_entry['product_string']))

    def pick_endpoint(self, endpoints):
        """FF60 channels: prefer interface 3 (32B short) for wireless, and
        interface 4 (64B feature) is exposed as usb. Operations decide
        per-plan; we hand back the short-channel endpoint as primary."""
        ff60 = [e for e in endpoints if e['usage_page'] == 0xFF60]
        if not ff60:
            raise ConfigError('没有可识别的 FF60 配置通道')
        by_if = {e['interface_number']: e for e in ff60}
        primary = by_if.get(3) or ff60[0]
        return {'path': primary['path'], 'connection': 'wireless' if 3 in by_if else 'usb'}

    # ---- lifecycle -------------------------------------------------------

    def probe(self, transport, connection):
        # Read-only open is itself the probe; a mismatched device would have
        # failed matching. No side-effect packets sent here.
        return {'name': 'GANSS GS3104T PRO', 'connection': connection,
                'hint': '映射生效前请按 Fn+Tab 开启驱动自定义按键'}

    def read_state(self, transport, connection):
        # No hardware readback exists for keymap; lighting per-key read paths
        # are unverified. Shadow state is the source of truth.
        shadow = load_shadow(self.plugin_id, _default_shadow)
        return {'connection': connection, 'shadow': shadow,
                'readback': 'none', 'fn_tab_required': True}

    # ---- config operations -------------------------------------------------

    def apply_config(self, transport, connection, module, patch):
        if module == 'lighting':
            return self._apply_lighting(transport, connection, patch)
        if module == 'keymap':
            return self._apply_keymap(transport, connection, patch)
        raise ConfigError(f'未知模块: {module}')

    def _apply_lighting(self, transport, connection, patch):
        plan = P.light_plan(connection=connection,
                            mode=patch.get('mode', 11),
                            brightness=patch.get('brightness', 5),
                            speed=patch.get('speed', 3),
                            color=patch.get('color', 'FFFFFF'),
                            colorful=patch.get('colorful', False))
        completed = self._execute(transport, plan)
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
        plan = P.keymap_single_plan(source, target, layer=layer, connection=connection)
        completed = self._execute(transport, plan)
        shadow = load_shadow(self.plugin_id, _default_shadow)
        shadow.setdefault('keymap', {}).setdefault(layer, {})[source] = target
        save_shadow(self.plugin_id, shadow)
        return {'completed_steps': completed, 'verified': 'ack_only',
                'note': '若按键未生效，请检查 Fn+Tab 是否开启驱动自定义按键'}

    def reset_default(self, transport, connection, scope):
        if scope != 'key':
            raise ConfigError('当前版本支持单键恢复；整层恢复请用 device.apply keymap target=default')
        raise ConfigError('reset 需要 patch.source 指明按键')

    def _execute(self, transport, plan):
        try:
            return execute(plan, _TransportAdapter(transport), time.sleep)
        except ProtocolError as e:
            raise TransferError(str(e)) from e

    # ---- frontend data ----------------------------------------------------

    def keys_list(self):
        import json
        km = json.loads((PLUGIN_DIR / 'data' / 'keymap.json').read_text(encoding='utf-8'))
        return [{'index': int(k['key_index']), 'name': k['name'], 'usage': k['code'],
                 'rect': [int(k['rect_left']), int(k['rect_top']),
                          int(k['rect_width']), int(k['rect_height'])]}
                for k in km]


def _default_shadow():
    return {'lighting': {'mode': 11, 'brightness': 5, 'speed': 3,
                         'color': 'FFFFFF', 'colorful': False},
            'keymap': {'normal': {}, 'fn': {}}}


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
        raw = self.t.get_feature(0, 64)
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
