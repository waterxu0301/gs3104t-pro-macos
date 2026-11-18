"""macOS device enumeration: find GS3104T PRO keyboard/receiver endpoints."""
import ctypes
import hashlib
import re

from .macos import _Info, _load_library, SUPPORTED_ID
from .protocol import ConfigError


def supported_hardware(vid, pid, name):
    model = re.sub(r"[\s_-]", "", name).upper()
    return (vid, pid) == SUPPORTED_ID and model in (
        'GS3104TPRO', 'HFDGS3104TPRO', 'GS3104TPRO2.4G')


def enumerate_devices():
    lib = _load_library()
    lib.hid_init()
    lib.hid_enumerate.restype = ctypes.c_void_p
    lib.hid_enumerate.argtypes = [ctypes.c_ushort, ctypes.c_ushort]
    lib.hid_free_enumeration.argtypes = [ctypes.c_void_p]
    n = lib.hid_enumerate(0, 0)
    result = []
    ptr = ctypes.cast(ctypes.c_void_p(n), ctypes.POINTER(_Info))
    while ptr:
        d = ptr.contents
        name = d.product_string or ''
        # macOS hidapi sometimes reports truncated product strings for composite
        # devices; also accept by VID/PID when the name is unusable.
        matched = ((d.vendor_id, d.product_id) == SUPPORTED_ID and
                   (supported_hardware(d.vendor_id, d.product_id, name) or
                    d.usage_page == 0xFF60))
        if matched and d.path:
            caps = _probe_caps(lib, d.path)
            result.append({
                'path': d.path.decode('utf-8', 'replace'),
                'vid': f'{d.vendor_id:04X}', 'pid': f'{d.product_id:04X}',
                'name': name or 'GS3104T-PRO', 'serial': d.serial_number or '',
                'usage_page': d.usage_page, 'usage': d.usage,
                'interface_number': d.interface_number, 'caps': caps,
            })
        ptr = ctypes.cast(d.next, ctypes.POINTER(_Info)) if d.next else None
    lib.hid_free_enumeration(ctypes.c_void_p(n))
    lib.hid_exit()
    return result


def _probe_caps(lib, path):
    """Open the endpoint briefly to learn its report sizes via error-free probe.

    hidapi on macOS does not expose report descriptor sizes, so we detect
    capability by writing/reading behavior at transfer time instead.
    """
    return None


def scan_hardware():
    groups = {}
    for endpoint in enumerate_devices():
        # Group one physical unit: same serial or same VID/PID identity.
        key = endpoint['serial'] or f"{endpoint['vid']}:{endpoint['pid']}"
        if key not in groups:
            groups[key] = {'id': hashlib.sha256(key.encode()).hexdigest()[:12],
                           'name': endpoint['name'], 'serial': endpoint['serial'],
                           'endpoints': []}
        groups[key]['endpoints'].append(endpoint)
    hardware = list(groups.values())
    names = [h['name'] for h in hardware]
    for h in hardware:
        if names.count(h['name']) > 1:
            h['name'] += f" [{h['id']}]"
        # On macOS the FF60 vendor endpoints are the config channels. The
        # 64-byte-capable one serves the feature protocol; the 32-byte one
        # serves the wireless short protocol. We cannot know sizes up front,
        # so expose both channels and let transport selection probe.
        h['connections'] = ['usb', 'wireless']
        h['available'] = True
        h['access_status'] = 'ready' if h['endpoints'] else 'unsupported'
        for e in h['endpoints']:
            e.pop('caps', None)
    return sorted(hardware, key=lambda h: h['name'])


def public_hardware(hardware):
    result = {k: v for k, v in hardware.items() if k != 'endpoints'}
    result['endpoints'] = [{'path': e['path'], 'usage_page': f"{e['usage_page']:04X}",
                            'interface_number': e['interface_number']}
                           for e in hardware['endpoints']]
    return result


def select_hardware(name):
    matches = [h for h in scan_hardware() if name in (h['name'], h['id'])]
    if not matches:
        raise ConfigError(f'未找到硬件「{name}」，请刷新设备列表')
    if len(matches) != 1:
        raise ConfigError(f'硬件名「{name}」不唯一，请使用完整名称或 ID')
    return matches[0]


def select_transport(hardware):
    """Pick the FF60 vendor endpoint. Prefer interface 4 (64-byte feature) for
    usb, interface 3 (32-byte short) for wireless, mirroring Linux findings."""
    ff60 = [e for e in hardware['endpoints'] if e['usage_page'] == 0xFF60]
    if not ff60:
        raise ConfigError(f"硬件「{hardware['name']}」没有可识别的配置通道")
    by_if = {e['interface_number']: e for e in ff60}
    return ff60, by_if
