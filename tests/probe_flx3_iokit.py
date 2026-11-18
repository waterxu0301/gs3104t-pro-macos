"""ctypes IOHIDManager probe for FLX3 receiver (seize mode)."""
import ctypes, ctypes.util, time

iokit = ctypes.CDLL(ctypes.util.find_library('IOKit'))
cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))

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
iokit.IOHIDManagerSetDeviceMatching.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
iokit.IOHIDManagerOpen.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
iokit.IOHIDManagerCopyDevices.restype = ctypes.c_void_p
iokit.IOHIDManagerCopyDevices.argtypes = [ctypes.c_void_p]
iokit.IOHIDManagerScheduleWithRunLoop.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
iokit.IOHIDDeviceSetReport.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_long]
iokit.IOHIDDeviceGetReport.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_long]
# IOHIDDeviceGetProperty returns CFTypeRef; use CFNumberGetValue for ints
iokit.IOHIDDeviceGetProperty.restype = ctypes.c_void_p
iokit.IOHIDDeviceGetProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
cf.CFGetTypeID.restype = ctypes.c_ulong
cf.CFNumberGetTypeID.restype = ctypes.c_ulong

kIOHIDOptionsTypeSeizeDevice = 0x00010000
kIOHIDReportTypeFeature = 2
kCFNumberIntType = 9


def cfstr(s):
    return cf.CFStringCreateWithCString(None, s.encode(), 0x08000100)


def num(v):
    v = ctypes.c_int(v)
    return cf.CFNumberCreate(None, kCFNumberIntType, ctypes.byref(v))


def get_int(dev, key):
    ref = iokit.IOHIDDeviceGetProperty(dev, cfstr(key))
    if not ref:
        return None
    out = ctypes.c_int(0)
    cf.CFNumberGetValue(ref, kCFNumberIntType, ctypes.byref(out))
    return out.value


def main():
    manager = iokit.IOHIDManagerCreate(None, kIOHIDOptionsTypeSeizeDevice)
    match = cf.CFDictionaryCreateMutable(None, 0, None, None)
    cf.CFDictionarySetValue(match, cfstr('VendorID'), num(0x04F3))
    cf.CFDictionarySetValue(match, cfstr('ProductID'), num(0x026F))
    iokit.IOHIDManagerSetDeviceMatching(manager, match)
    r = iokit.IOHIDManagerOpen(manager, kIOHIDOptionsTypeSeizeDevice)
    print('manager open:', r)
    
    time.sleep(0.5)
    devs = iokit.IOHIDManagerCopyDevices(manager)
    n = cf.CFSetGetCount(devs)
    print('seized devices:', n)
    if not n:
        return
    arr = (ctypes.c_void_p * n)()
    cf.CFSetGetValues(devs, arr)
    target = None
    for i in range(n):
        dev = arr[i]
        page = get_int(dev, 'PrimaryUsagePage')
        maxft = get_int(dev, 'MaxFeatureReportSize') or 0
        maxin = get_int(dev, 'MaxInputReportSize') or 0
        print(f'  dev page={page:#x} maxIn={maxin} maxFeat={maxft}')
        if maxft >= 32:
            target = dev
    if target is None and n:
        target = arr[0]
    if not target:
        print('no target'); return
    # FLX3 GET_DEVICE_INFO: wn packet [AA, cmd=16, len=48, addr 0/0, data at 8]
    pkt = bytearray(32)
    pkt[0] = 0xAA; pkt[1] = 16; pkt[2] = 48
    buf = ctypes.create_string_buffer(bytes(pkt), 32)
    r = iokit.IOHIDDeviceSetReport(target, kIOHIDReportTypeFeature, 6, buf, 32)
    print('set feature reportId6:', r)
    time.sleep(0.4)
    out = ctypes.create_string_buffer(64)
    # GET via feature report id 6 (command status) — device pushes input reports;
    # also try get
    # async input callback: register for reportId 6 acks + 4 telemetry
    CB = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)
    received = []
    def on_input(_ctx, _type, _rst, report):
        ln = iokit.IOHIDReportGetLength(report, 1)  # kIOHIDReportTypeInput=1
        raw = ctypes.string_at(iokit.IOHIDReportGetBytes(report, None), ln) if True else b''
        received.append((ln, raw.hex(' ')))
    # NOTE: getting report bytes requires IOHIDReportGetBytes API which may not
    # be public; simpler: schedule runloop and just print that ack arrived.
    mode = cfstr('kCFRunLoopDefaultMode')
    iokit.IOHIDDeviceScheduleWithRunLoop(target, cf.CFRunLoopGetCurrent(), mode)
    print('listening for input reports for 2s...')
    cf.CFRunLoopRunInMode(mode, 2.0, 0)
    print('done')


if __name__ == '__main__':
    main()
