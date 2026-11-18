"""Plugin discovery, enable/disable state, device enumeration & routing."""
import importlib
import json
import re
import shutil
import threading
from pathlib import Path

import hid

from .base_driver import BaseDeviceDriver
from .errors import ConfigError, FrameworkError
from .safety import SafetyGuard

PLUGIN_ROOT = Path(__file__).resolve().parent / 'plugins'
STATE_PATH = Path.home() / '.config' / 'ganss-driver' / 'plugins-state.json'


def _load_state():
    if STATE_PATH.exists():
        try:
            return json.loads(STATE_PATH.read_text(encoding='utf-8'))
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def _save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding='utf-8')


def _entry_matches(entry, rule):
    """AND-combined multi-condition matcher. Never matches on VID alone."""
    if 'vid' in rule and entry['vendor_id'] != int(rule['vid'], 16):
        return False
    if 'pid' in rule:
        pids = rule['pid'] if isinstance(rule['pid'], list) else [rule['pid']]
        if entry['product_id'] not in (int(p, 16) for p in pids):
            return False
    if 'usage_page' in rule and entry['usage_page'] != int(rule['usage_page'], 16):
        return False
    if 'usage' in rule and entry['usage'] != int(rule['usage'], 16):
        return False
    if 'interface_number' in rule and entry['interface_number'] not in rule['interface_number']:
        return False
    if 'product_regex' in rule:
        name = entry['product_string'] or ''
        if not re.search(rule['product_regex'], name, re.IGNORECASE):
            return False
    return True


def _entry_valid(entry):
    """Skip macOS composite entries with unusable identity (0000:0000)."""
    return not (entry['vendor_id'] == 0 and entry['product_id'] == 0 and
                not (entry['usage_page'] >= 0xFF00))


class PluginManager:
    def __init__(self, plugin_root=PLUGIN_ROOT):
        self.plugin_root = Path(plugin_root)
        self.plugins = {}       # plugin_id -> {'manifest', 'module', 'driver_cls'}
        self.state = _load_state()
        self._lock = threading.Lock()
        self.reload()

    # ---- discovery -------------------------------------------------------

    def reload(self):
        with self._lock:
            self.plugins.clear()
            if not self.plugin_root.exists():
                return
            for d in sorted(self.plugin_root.iterdir()):
                manifest_path = d / 'manifest.json'
                if not manifest_path.is_file():
                    continue
                try:
                    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
                except (json.JSONDecodeError, OSError) as e:
                    continue
                pid = manifest.get('plugin_id', d.name)
                try:
                    mod = importlib.import_module(f'framework.plugins.{d.name}.driver')
                    driver_cls = getattr(mod, 'Driver')
                    assert issubclass(driver_cls, BaseDeviceDriver)
                except (ImportError, AttributeError, AssertionError):
                    continue
                self.plugins[pid] = {'manifest': manifest, 'module': mod,
                                     'driver_cls': driver_cls, 'dir': d}

    # ---- plugin lifecycle -------------------------------------------------

    def list_plugins(self):
        result = []
        for pid, p in self.plugins.items():
            m = p['manifest']
            result.append({
                'plugin_id': pid,
                'name': m.get('name', pid),
                'device_type': m.get('device_type'),
                'version': m.get('version'),
                'capabilities': m.get('capabilities', []),
                'ui_modules': m.get('ui_modules', []),
                'enabled': self.state.get(pid, {}).get('enabled', True),
            })
        return result

    def set_enabled(self, plugin_id, enabled):
        if plugin_id not in self.plugins:
            raise ConfigError(f'未知插件: {plugin_id}')
        st = self.state.setdefault(plugin_id, {})
        st['enabled'] = bool(enabled)
        _save_state(self.state)

    def remove_plugin(self, plugin_id):
        p = self.plugins.get(plugin_id)
        if not p:
            raise ConfigError(f'未知插件: {plugin_id}')
        shutil.rmtree(p['dir'])
        self.state.pop(plugin_id, None)
        _save_state(self.state)
        self.reload()

    def get_manifest(self, plugin_id):
        if plugin_id not in self.plugins:
            raise ConfigError(f'未知插件: {plugin_id}')
        return self.plugins[plugin_id]['manifest']

    def get_driver(self, plugin_id):
        if plugin_id not in self.plugins:
            raise ConfigError(f'未知插件: {plugin_id}')
        if not self.state.get(plugin_id, {}).get('enabled', True):
            raise ConfigError(f'插件已禁用: {plugin_id}')
        return self.plugins[plugin_id]['driver_cls']()

    # ---- device enumeration ------------------------------------------------

    def enumerate_all(self):
        """Scan hidapi for all entries, route through enabled plugins' match
        rules, group into physical devices, and open-probe each candidate."""
        entries = []
        for e in hid.enumerate():
            item = {
                'path': e['path'], 'vendor_id': e['vendor_id'],
                'product_id': e['product_id'], 'product_string': e['product_string'] or '',
                'serial_number': e['serial_number'] or '',
                'usage_page': e['usage_page'], 'usage': e['usage'],
                'interface_number': e['interface_number'],
            }
            if _entry_valid(item):
                entries.append(item)
        devices = []
        # mock preview mode for UI development (GANSS_FLX3_MOCK=1)
        from .plugins.ganss_flx3.mock import mock_enabled, MockDevice
        if mock_enabled() and 'ganss_flx3' in self.plugins:
            if self.state.get('ganss_flx3', {}).get('enabled', True):
                devices.append(MockDevice().as_device())
        for pid, p in self.plugins.items():
            if not self.state.get(pid, {}).get('enabled', True):
                continue
            driver = p['driver_cls']()
            matched = [e for e in entries if self._match_any(e, p['manifest'], driver)]
            if not matched:
                continue
            for group in driver.scan_endpoints(matched):
                try:
                    info = self._probe_group(pid, driver, group)
                    info['plugin_id'] = pid
                    info['device_type'] = p['manifest'].get('device_type')
                    info['capabilities'] = p['manifest'].get('capabilities', [])
                    info['ui_modules'] = p['manifest'].get('ui_modules', [])
                    devices.append(info)
                except FrameworkError:
                    continue  # matched but channel unusable; skip silently
        return devices

    def _match_any(self, entry, manifest, driver):
        for rule in manifest.get('match', []):
            if _entry_matches(entry, rule):
                return True
        return False

    def _probe_group(self, plugin_id, driver, endpoints):
        """Pick the endpoint the driver prefers, open it read-only, probe."""
        transport_info = driver.pick_endpoint(endpoints)
        if transport_info.get('readonly') or transport_info.get('path') is None:
            base = driver.probe(None, transport_info['connection'])
        elif hasattr(driver, 'open_transport'):
            t = driver.open_transport(transport_info)
            try:
                base = driver.probe(t, transport_info['connection'])
            finally:
                t.close()
        else:
            from .transport import HidTransport
            with HidTransport(transport_info['path']) as t:
                base = driver.probe(t, transport_info['connection'])
        base['endpoints'] = [{'path': (e['path'].decode('utf-8', 'replace')
                                       if isinstance(e['path'], bytes) else str(e['path'])),
                              'usage_page': f"{e['usage_page']:04X}",
                              'interface_number': e['interface_number']}
                             for e in endpoints]
        base['device_id'] = f"{plugin_id}:{abs(hash(tuple(e['path'] for e in endpoints))) % 100000:05d}"
        return base

    # ---- device-scoped operations -------------------------------------------

    def resolve_device(self, device_id):
        """device_id format '<plugin_id>:<suffix>' from enumerate_all."""
        plugin_id, _, _ = device_id.partition(':')
        driver = self.get_driver(plugin_id)
        manifest = self.get_manifest(plugin_id)
        devices = self.enumerate_all()
        match = [d for d in devices if d['device_id'] == device_id]
        if not match:
            raise ConfigError(f'设备未连接或已变更: {device_id}')
        return plugin_id, driver, manifest, match[0]

    def guard_for(self, manifest):
        return SafetyGuard(manifest)
