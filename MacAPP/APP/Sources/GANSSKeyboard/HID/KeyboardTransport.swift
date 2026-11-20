import Foundation
import IOKit.hid

/// 与 GS3104T-PRO 键盘的底层 HID 传输层。
///
/// 设备暴露两个厂商自定义通道（UsagePage=0xFF60, Usage=0x61）：
///  - MI_03：32 字节 Input/Output 报告 → 协议 C2（33 字节帧：报告ID + 32字节，末字节为校验和）
///           这是 config.xml 中声明的 2.4G 配置接口，也是 Windows 驱动 WriteFile/ReadFile 使用的通道。
///  - MI_04：64 字节 Input/Output 报告 → 协议 C1（65 字节帧：报告ID + 64字节）
///           对应 Windows 驱动 HidD_SetFeature(0x41) 的大数据/会话通道。
public final class KeyboardTransport: @unchecked Sendable {

    public enum ChannelKind: String, Comparable, Sendable {
        case c2_32   // MI_03, 32 字节
        case c1_64   // MI_04, 64 字节
        public static func < (a: ChannelKind, b: ChannelKind) -> Bool { a.rawValue < b.rawValue }
        var reportSize: Int { self == .c2_32 ? 32 : 64 }
    }

    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let direction: String   // "TX" / "RX" / "!!"
        public let channel: String
        public let bytes: [UInt8]
        public let text: String?
        public var hex: String {
            if let text { return text }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    public enum TransportError: Error, LocalizedError {
        case notConnected
        case disconnected
        case timeout
        case ioError(Int32)

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "未找到键盘配置通道"
            case .disconnected: return "键盘已断开"
            case .timeout: return "键盘无响应（无线键盘可能已休眠，请按任意键唤醒后重试）"
            case .ioError(let c): return "HID IO 错误 0x\(String(UInt32(bitPattern: c), radix: 16))"
            }
        }
    }

    private struct Channel {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        let context: UnsafeMutableRawPointer
    }

    private var manager: IOHIDManager?
    private var channels: [ChannelKind: Channel] = [:]
    private let queue = DispatchQueue(label: "ganss.hid")
    private var pending: (continuation: CheckedContinuation<[UInt8], Error>, kind: ChannelKind)?
    private var waitTimer: DispatchWorkItem?

    public var onLog: ((LogEntry) -> Void)?
    public var onDeviceChange: ((_ connected: Bool, _ detail: String) -> Void)?

    public init() {}

    // MARK: - 生命周期

    public func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x024F
        ] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        KeyboardTransport.activeTransport = self
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, _ in
            KeyboardTransport.activeTransport?.rescan()
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, _ in
            KeyboardTransport.activeTransport?.rescan()
        }, nil)
        rescan()
        if openResult != 0 {
            log("!!", "-", []); logText("IOHIDManagerOpen 失败 0x\(String(UInt32(bitPattern: openResult), radix: 16))（可能需要在「系统设置 › 隐私与安全性 › 输入监控」中授权）")
        }
    }

    private static weak var activeTransport: KeyboardTransport?

    public func stop() {
        failPending(with: TransportError.disconnected)
        if let mgr = manager { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
        releaseChannels()
    }

    public var isConnected: Bool { !channels.isEmpty }
    public var connectedChannels: [ChannelKind] { channels.keys.sorted() }

    private func releaseChannels() {
        for (_, ch) in channels {
            IOHIDDeviceRegisterInputReportCallback(ch.device, ch.buffer, ch.size + 1, nil, nil)
            ch.context.deallocate()
            ch.buffer.deallocate()
        }
        channels = [:]
    }

    private func rescan() {
        guard let mgr = manager else { return }
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            if !channels.isEmpty {
                releaseChannels()
                onDeviceChange?(false, "键盘已断开")
            }
            return
        }
        var found: [ChannelKind: IOHIDDevice] = [:]
        for dev in set {
            let page = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            guard UInt64(page) == 0xFF60, UInt64(usage) == 0x61 else { continue }
            guard let desc = IOHIDDeviceGetProperty(dev, kIOHIDReportDescriptorKey as CFString) as? Data else { continue }
            var reportCount = 0
            var i = 0
            while i < desc.count - 1 {
                if desc[i] == 0x95 { reportCount = Int(desc[i + 1]); break }
                i += 1
            }
            if reportCount == 32 { found[.c2_32] = dev }
            else if reportCount == 64 { found[.c1_64] = dev }
        }
        let changed = found.keys.sorted() != channels.keys.sorted()
        guard changed else { return }
        releaseChannels()
        for (kind, dev) in found {
            let size = kind.reportSize
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size + 1)
            buf.initialize(repeating: 0, count: size + 1)
            let ctx = Unmanaged.passRetained(InputContext(kind: kind, owner: self)).toOpaque()
            let ch = Channel(device: dev, buffer: buf, size: size, context: ctx)
            channels[kind] = ch
            IOHIDDeviceRegisterInputReportCallback(dev, buf, size + 1, Self.inputCallback, ctx)
        }
        let detail = channels.keys.sorted().map { $0.rawValue }.joined(separator: ", ")
        onDeviceChange?(!channels.isEmpty, channels.isEmpty ? "键盘已断开" : "已连接配置通道: \(detail)")
    }

    private final class InputContext {
        let kind: ChannelKind
        weak var owner: KeyboardTransport?
        init(kind: ChannelKind, owner: KeyboardTransport) { self.kind = kind; self.owner = owner }
    }

    private static let inputCallback: IOHIDReportCallback = { ctx, _, _, _, _, bytes, len in
        guard let ctx = ctx else { return }
        let ic = Unmanaged<InputContext>.fromOpaque(ctx).takeUnretainedValue()
        let data = Array(UnsafeBufferPointer(start: bytes, count: len))
        ic.owner?.handleInput(kind: ic.kind, data: data)
    }

    private func handleInput(kind: ChannelKind, data: [UInt8]) {
        log("RX", kind.rawValue, data)
        queue.sync {
            if let p = pending, p.kind == kind {
                waitTimer?.cancel()
                waitTimer = nil
                pending = nil
                p.continuation.resume(returning: data)
            }
        }
    }

    // MARK: - 收发

    /// 发送 32 字节载荷到 C2 通道（MI_03），等待输入报告应答。
    public func request32(_ payload: [UInt8], timeout: TimeInterval = 0.8) async throws -> [UInt8] {
        try await request(kind: .c2_32, payload: payload, timeout: timeout)
    }

    /// 发送 64 字节载荷到 C1 通道（MI_04），等待输入报告应答。
    public func request64(_ payload: [UInt8], timeout: TimeInterval = 0.8) async throws -> [UInt8] {
        try await request(kind: .c1_64, payload: payload, timeout: timeout)
    }

    /// 只发送不等待应答。
    public func send(_ kind: ChannelKind, _ payload: [UInt8]) throws {
        guard let ch = channels[kind] else { throw TransportError.notConnected }
        var data = payload
        let expected = kind.reportSize
        while data.count < expected { data.append(0) }
        if data.count > expected { data = Array(data.prefix(expected)) }
        log("TX", kind.rawValue, data)
        let ret = data.withUnsafeMutableBytes { raw -> IOReturn in
            IOHIDDeviceSetReport(ch.device, kIOHIDReportTypeOutput, 0, raw.baseAddress!, raw.count)
        }
        if ret != 0 { throw TransportError.ioError(ret) }
    }

    private func request(kind: ChannelKind, payload: [UInt8], timeout: TimeInterval) async throws -> [UInt8] {
        guard channels[kind] != nil else { throw TransportError.notConnected }
        return try await withCheckedThrowingContinuation { cont in
            var rejected = false
            queue.sync {
                if pending != nil { rejected = true }
                else { pending = (cont, kind) }
            }
            if rejected {
                cont.resume(throwing: TransportError.timeout)
                return
            }
            do {
                try send(kind, payload)
            } catch {
                queue.sync {
                    waitTimer?.cancel(); waitTimer = nil
                    if let p = pending, p.kind == kind { pending = nil; p.continuation.resume(throwing: error) }
                }
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.sync {
                    guard let p = self.pending, p.kind == kind else { return }
                    self.pending = nil
                    p.continuation.resume(throwing: TransportError.timeout)
                }
            }
            queue.sync {
                waitTimer?.cancel()
                waitTimer = work
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    private func failPending(with error: Error) {
        queue.sync {
            waitTimer?.cancel(); waitTimer = nil
            if let p = pending { pending = nil; p.continuation.resume(throwing: error) }
        }
    }

    private func log(_ dir: String, _ channel: String, _ bytes: [UInt8]) {
        let entry = LogEntry(date: Date(), direction: dir, channel: channel, bytes: bytes, text: nil)
        if Thread.isMainThread { onLog?(entry)
        } else { DispatchQueue.main.async { self.onLog?(entry) } }
    }

    private func logText(_ msg: String) {
        let entry = LogEntry(date: Date(), direction: "!!", channel: "-", bytes: [], text: msg)
        if Thread.isMainThread { onLog?(entry)
        } else { DispatchQueue.main.async { self.onLog?(entry) } }
    }
}
