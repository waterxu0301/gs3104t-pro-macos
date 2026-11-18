"""macOS HID transport using hidapi C API via ctypes (libusb/IOKit backend).

Mirrors the Linux hidraw semantics used by protocol.runner:
- Feature channel (wired): 65-byte API buffers, first byte report ID 0.
- Short channel (2.4G): 33-byte API output buffers; input read returns 32 bytes.
"""
import ctypes
import platform
import time

from .protocol import ConfigError

LIB_NAMES = [
    'libhidapi.dylib',
    'libhidapi-iohidmanager.dylib',
    'libhidapi-iohidmanager.so.0',
    'libhidapi-hidraw.dylib',
    'libhidapi-libusb.dylib',
]

SUPPORTED_ID = (0x05AC, 0x024F)


def _library_path():
    """Prefer the hidapi bundled inside the venv's pip 'hid' extension module."""
    import os
    here = os.path.dirname(__file__)
    candidate = os.path.join(here, '..', '.venv', 'lib', 'python3.12', 'site-packages',
                             'hid.cpython-312-darwin.so')
    if os.path.exists(candidate):
        return candidate
    return None


def _load_library():
    import glob
    embedded = _library_path()
    if embedded:
        try:
            return ctypes.CDLL(embedded)
        except OSError:
            pass
    candidates = []
    for name in LIB_NAMES:
        candidates += glob.glob(f'/opt/homebrew/lib/{name}*')
        candidates += glob.glob(f'/usr/local/lib/{name}*')
    candidates += LIB_NAMES  # bare soname search
    for path in candidates:
        try:
            return ctypes.CDLL(path)
        except OSError:
            continue
    raise ConfigError(
        '未找到 hidapi 动态库；请先安装: brew install hidapi')


class _Info(ctypes.Structure):
    _fields_ = [
        ('path', ctypes.c_char_p),
        ('vendor_id', ctypes.c_ushort),
        ('product_id', ctypes.c_ushort),
        ('serial_number', ctypes.c_wchar_p),
        ('release_number', ctypes.c_ushort),
        ('manufacturer_string', ctypes.c_wchar_p),
        ('product_string', ctypes.c_wchar_p),
        ('usage_page', ctypes.c_ushort),
        ('usage', ctypes.c_ushort),
        ('interface_number', ctypes.c_int),
        ('next', ctypes.c_void_p),
    ]


class MacHid:
    """Device handle on macOS. connection: 'usb' (feature) or 'wireless' (short)."""

    def __init__(self, device_path, connection, trace=None):
        self.device_path = device_path
        self.connection = connection
        self.trace = trace
        self.lib = _load_library()
        self._setup_prototypes()
        self.handle = None

    def _setup_prototypes(self):
        lib = self.lib
        lib.hid_init.restype = ctypes.c_int
        lib.hid_exit.restype = ctypes.c_int
        lib.hid_enumerate.restype = ctypes.c_void_p
        lib.hid_enumerate.argtypes = [ctypes.c_ushort, ctypes.c_ushort]
        lib.hid_free_enumeration.argtypes = [ctypes.c_void_p]
        lib.hid_open_path.restype = ctypes.c_void_p
        lib.hid_open_path.argtypes = [ctypes.c_char_p]
        lib.hid_close.argtypes = [ctypes.c_void_p]
        lib.hid_write.restype = ctypes.c_int
        lib.hid_write.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
        lib.hid_read_timeout.restype = ctypes.c_int
        lib.hid_read_timeout.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
        lib.hid_get_feature_report.restype = ctypes.c_int
        lib.hid_get_feature_report.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
        lib.hid_send_feature_report.restype = ctypes.c_int
        lib.hid_send_feature_report.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
        lib.hid_get_product_string.restype = ctypes.c_int
        lib.hid_get_product_string.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_size_t]
        lib.hid_set_nonblocking.restype = ctypes.c_int
        lib.hid_set_nonblocking.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.hid_init()

    def _error(self, action):
        raise OSError(f'{action} 失败（hidapi 未能完成操作）') from None

    def _log(self, direction, channel, data):
        if self.trace:
            self.trace({'direction': direction, 'channel': channel,
                        'hex': bytes(data).hex(' ')})

    def __enter__(self):
        handle = self.lib.hid_open_path(self.device_path.encode('utf-8'))
        if not handle:
            raise PermissionError('无法打开 HID 设备；macOS 下键盘类接口可能被系统独占，'
                                  '请尝试 USB 有线连接或确认没有其他驱动占用')
        self.handle = handle
        return self

    def __exit__(self, *_):
        if self.handle:
            self.lib.hid_close(ctypes.c_void_p(self.handle))
            self.handle = None

    def send_feature(self, data):
        # data is 65 bytes including leading report-ID 0; hidapi expects the
        # first byte to be the report number, so send data[1:] with ID implied.
        self._log('send', 'feature', data)
        payload = bytes(data[1:]) if data[0] == 0 else bytes(data)
        n = self.lib.hid_send_feature_report(
            ctypes.c_void_p(self.handle), payload, len(payload))
        if n != len(payload):
            self._error('Feature 写入')

    def get_feature(self):
        buf = ctypes.create_string_buffer(65)
        buf[0] = b'\x00'
        n = self.lib.hid_get_feature_report(
            ctypes.c_void_p(self.handle), buf, 65)
        if n < 0:
            self._error('Feature 读取')
        # macOS IOKit returns the 65-byte API buffer starting with report ID 0.
        if n == 65 and buf.raw[0] == 0:
            payload = buf.raw[1:65]
        elif n == 64:
            payload = buf.raw[:64]
        else:
            raise OSError(f'Feature 响应长度或 Report ID 异常: {n}')
        self._log('receive', 'feature', payload)
        return payload

    def short_exchange(self, data):
        self._log('send', 'short', data)
        n = self.lib.hid_write(ctypes.c_void_p(self.handle), bytes(data), len(data))
        if n != len(data):
            self._error('Output 写入')
        deadline = time.monotonic() + 0.4
        while time.monotonic() < deadline:
            buf = ctypes.create_string_buffer(64)
            got = self.lib.hid_read_timeout(
                ctypes.c_void_p(self.handle), buf, 64,
                int(max(0, (deadline - time.monotonic())) * 1000))
            if got <= 0:
                break
            response = buf.raw[:got]
            self._log('receive', 'short', response)
            if len(response) >= 3 and response[:3] == data[1:4]:
                return
        raise TimeoutError('未收到匹配的无线命令回显；事务未确认，后续报文已停止')
