import Foundation
import IOKit.hid

/// 监听 GS3104T-PRO 自身的原始键盘输入（boot 键盘接口 page=1 usage=6），
/// 供首页预览图实时高亮"当前按下的键"。
///
/// 实测（2026-11-19）：`IOHIDManagerOpen` 返回 0，**无需任何额外授权**
/// （相比之下 NSEvent 全局监听需要辅助功能权限）。
///
/// 报告格式（8 字节 boot keyboard）：
/// ```
/// [0]     modifier 位图  bit0..7 = LCtrl LShift LAlt LWin RCtrl RShift RAlt RWin
/// [1]     保留 0
/// [2..7]  最多 6 个同时按下的 usage code
/// ```
/// 全 0 表示全部释放。
///
/// 只匹配 GS3104T-PRO（VID 05AC / PID 024F），其他键盘不会干扰。
public final class KeyMonitor: @unchecked Sendable {

    /// 当前按下的 HID usage code 集合（含修饰键 0xE0..0xE7）
    public private(set) var pressed: Set<UInt8> = []
    /// 上次 IOHIDManagerOpen 的返回值（0 = 成功；0xe00002e2 = 输入监控权限不足）
    public private(set) var lastOpenStatus: Int32 = 0
    /// 是否已获得「输入监控」权限
    public var isAuthorized: Bool { lastOpenStatus == 0 }
    public var onChange: ((Set<UInt8>) -> Void)?

    private var manager: IOHIDManager?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private let lock = NSLock()

    public init() {}

    /// 文件日志：不受启动方式/unified log 过滤影响
    private func flog(_ msg: String) {
        let path = "/tmp/ganss_keymon.log"
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path),
           let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            h.seekToEndOfFile(); h.write(data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    public func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x024F,
            kIOHIDPrimaryUsagePageKey: 1,     // Generic Desktop
            kIOHIDPrimaryUsageKey: 6          // Keyboard
        ] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ret = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // 绑定设备后逐个注册 input report 回调
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
            for dev in set {
                let page = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
                let usage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
                guard page == 1, usage == 6 else { continue }
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
                buf.initialize(repeating: 0, count: 8)
                buffer = buf
                let ctx = Unmanaged.passRetained(self).toOpaque()
                IOHIDDeviceRegisterInputReportCallback(dev, buf, 8, Self.callback, ctx)
            }
        }
        let found = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>)?.count ?? 0
        flog("STARTED open=0x\(String(UInt32(bitPattern: ret), radix: 16)) devices=\(found)")
        NSLog("KeyMonitor started: open=0x%08x devices=%d", UInt32(bitPattern: ret), found)
        if ret != 0 {
            NSLog("KeyMonitor open failed: 0x%08x", UInt32(bitPattern: ret))
        }
    }

    public func stop() {
        manager.map { IOHIDManagerClose($0, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
        buffer?.deallocate()
        buffer = nil
    }

    private static let callback: IOHIDReportCallback = { ctx, _, _, _, _, bytes, len in
        guard let ctx else { return }
        let mon = Unmanaged<KeyMonitor>.fromOpaque(ctx).takeUnretainedValue()
        mon.handle(Array(UnsafeBufferPointer(start: bytes, count: len)))
    }

    private func handle(_ report: [UInt8]) {
        guard report.count >= 8 else { return }
        var now = Set<UInt8>()
        // 修饰键位图 → usage 0xE0..0xE7
        let mods = report[0]
        if mods != 0 {
            for i in 0..<8 where (mods >> i) & 1 == 1 {
                now.insert(0xE0 + UInt8(i))
            }
        }
        // 普通键 usage（跳过保留位与全 0）
        for i in 2..<min(8, report.count) {
            let u = report[i]
            if u != 0 { now.insert(u) }
        }
        NSLog("KeyMonitor raw: %@", report.map { String(format: "%02x", $0) }.joined())
        lock.lock()
        let changed = now != pressed
        pressed = now
        lock.unlock()
        if changed { NSLog("KeyMonitor pressed -> %@", now.sorted().map { String(format: "0x%02X", $0) }.joined(separator: ",")) }
        if changed {
            NSLog("KeyMonitor pressed -> %@", now.sorted().map { String(format: "0x%02X", $0) }.joined(separator: ","))
        }
        if changed {
            let snapshot = now
            if Thread.isMainThread { onChange?(snapshot) }
            else { DispatchQueue.main.async { self.onChange?(snapshot) } }
        }
    }
}
