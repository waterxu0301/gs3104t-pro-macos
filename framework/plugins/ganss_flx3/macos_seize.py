"""FLX3 macOS transport: IOHIDManager seize channel.

The FLX3 receiver's config collection is held exclusively by macOS while the
mouse is the active pointer device. hidapi open_path fails (EACCES-like), so
this transport opens via IOHIDManagerCreate with kIOHIDOptionsTypeSeizeDevice,
sends commands with IOHIDDeviceSetReport(feature, reportId=6, 32B) and reads
acks with IOHIDDeviceGetReport(feature, reportId=6).

Verified live: set=0/get=0 round trip (mouse asleep over BT → status=0 is the
expected physical state; channel itself works).
"""
import ctypes
import ctypes.util
import time

from framework.errors import TransportError

_REPORT_FEATURE = 2
REPORT_CMD = 6
REPORT_STATE = 5
REPORT_INPUT = 4


class IOKitSeizeTransport:
    """FLX3 config channel on macOS. report_id is explicit per framework spec."""

    def __init__(self, vendor_id=0x04F3, product_ids=(0x026F, 0x0276, 0x0277)):
        self.vendor_id = vendor_id
        self.product_ids = product_ids
        self.dev = None
        self.max_feature = 0

    # ---- low-level setup ---------------------------------------------------

    def _open(self):
        iokit = ctypes.CDLL(ctypes.util.find_library('IOKit'))
        cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
        self.iokit, self.cf = iokit, cf
        cf.CFDictionaryCreateMutable.restype = ctypes.c_void_p
        cf.CFDictionaryCreateMutable.argtypes = [ctypes.c_void_p] * 4
        cf.CFNumberCreate.restype = ctypes.c_void_p
        cf.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
        cf.CFDictionarySetValue.argtypes = [ctypes.c_void_p] * 3
        cf.CFSetGetCount.argtypes = [ctypes.c_void_p]
        cf.CFSetGetCount.restype = ctypes.c_long
        cf.CFSetGetValues.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFRunLoopGetCurrent.restype = ctypes.c_void_p
        iokit.IOHIDManagerCreate.restype = ctypes.c_void_p
        iokit.IOHIDManagerCreate.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        iokit.IOHIDManagerSetDeviceMatching.argtypes = [ctypes.c_void_p] * 2
        iokit.IOHIDManagerOpen.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        iokit.IOHIDManagerCopyDevices.restype = ctypes.c_void_p
        iokit.IOHIDManagerCopyDevices.argtypes = [ctypes.c_void_p]
        iokit.IOHIDManagerScheduleWithRunLoop.argtypes = [ctypes.c_void_p] * 3
        iokit.IOHIDDeviceSetReport.argtypes = [ctypes.c_void_p, ctypes.c_long,
                                               ctypes.c_long, ctypes.c_void_p, ctypes.c_long]
        iokit.IOHIDDeviceGetReport.argtypes = [ctypes.c_void_p, ctypes.c_long,
                                               ctypes.c_long, ctypes.c_void_p,
                                               ctypes.POINTER(ctypes.c_long)]
        iokit.IOHIDDeviceGetProperty.restype = ctypes.c_void_p
        iokit.IOHIDDeviceGetProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]

        mgr = iokit.IOHIDManagerCreate(None, 0x00010000)  # seize
        md = cf.CFDictionaryCreateMutable(None, 0, None, None)
        cf.CFDictionarySetValue(md, self._cfstr('VendorID'), self._num(self.vendor_id))
        # product list: use broad match on vid + pick by MaxFeatureReportSize
        iokit.IOHIDManagerSetDeviceMatching(mgr, md)
        r = iokit.IOHIDManagerOpen(mgr, 0x00010000)
        if r != 0:
            raise TransportError(f'IOHIDManager seize 打开失败: {r:#x}')
        self.mode = self._cfstr('kCFRunLoopDefaultMode')
        iokit.IOHIDManagerScheduleWithRunLoop(mgr, cf.CFRunLoopGetCurrent(), self.mode)
        time.sleep(0.4)
        devs = iokit.IOHIDManagerCopyDevices(mgr)
        n = cf.CFSetGetCount(devs)
        if not n:
            raise TransportError('未找到 FLX3 接收器')
        arr = (ctypes.c_void_p * n)()
        cf.CFSetGetValues(devs, arr)
        target = None
        for i in range(n):
            ft = self._get_int(arr[i], 'MaxFeatureReportSize') or 0
            pid = self._get_int(arr[i], 'ProductID')
            if ft >= 32 and pid in self.product_ids:
                target = arr[i]
                self.max_feature = ft
        if target is None:
            raise TransportError('接收器无 32B feature 通道（未按预期枚举）')
        self.dev = target
        return self

    def _cfstr(self, s):
        return self.cf.CFStringCreateWithCString(None, s.encode(), 0x08000100)

    def _num(self, v):
        v = ctypes.c_int(v)
        return self.cf.CFNumberCreate(None, 9, ctypes.byref(v))

    def _get_int(self, dev, key):
        ref = self.iokit.IOHIDDeviceGetProperty(dev, self._cfstr(key))
        if not ref:
            return None
        o = ctypes.c_int(0)
        self.cf.CFNumberGetValue(ref, 9, ctypes.byref(o))
        return o.value

    # ---- framework transport surface ----------------------------------------

    def open(self):
        return self._open()

    def close(self):
        self.dev = None

    def __enter__(self):
        return self.open()

    def __exit__(self, *_):
        self.close()

    def send_feature(self, report_id, payload):
        """payload: full 32-byte AA-header packet (no report ID byte)."""
        buf = ctypes.create_string_buffer(bytes(payload), len(payload))
        r = self.iokit.IOHIDDeviceSetReport(self.dev, _REPORT_FEATURE,
                                            report_id, buf, len(payload))
        if r != 0:
            raise TransportError(f'SetReport({report_id}) 失败: {r:#x}')

    def get_feature(self, report_id, length=64):
        out = ctypes.create_string_buffer(max(length, self.max_feature))
        ln = ctypes.c_long(max(length, self.max_feature))
        r = self.iokit.IOHIDDeviceGetReport(self.dev, _REPORT_FEATURE,
                                            report_id, out, ctypes.byref(ln))
        if r != 0:
            raise TransportError(f'GetReport({report_id}) 失败: {r:#x}')
        return bytes(out.raw[:ln.value])

    def poll_input(self, max_len, timeout_ms=10):
        """FLX3 acks arrive via feature GetReport(6), not input reports; this
        shim maps the framework's poll_input to a feature ack read."""
        try:
            raw = self.get_feature(REPORT_CMD, 32)
        except TransportError:
            return None
        if raw and len(raw) >= 2:
            return raw[0], raw[1:]
        return None

    def write_output(self, report_id, payload):
        self.send_feature(report_id, payload)
