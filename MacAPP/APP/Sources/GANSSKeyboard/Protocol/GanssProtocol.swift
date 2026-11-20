import Foundation

/// GS3104T-PRO 协议层（macOS 2.4G 短报文通道，已真机验证）
///
/// ## 实测结论（2026-11-19，键盘唤醒后）
/// 配置通道 = UsagePage 0xFF60 / Usage 0x61 / **MI_03（32 字节 Output+Input）**。
/// 64 字节的 MI_04 只回固定状态包 `0f 01 01 11`，**不是**命令通道。
///
/// ### 帧格式（发送 32 字节 Output 报告，report id = 0）
/// ```
/// [0]    cmd      命令字
/// [1]    len      payload 长度（0x10 = 16 等）
/// [2]    sub      次级参数
/// [3..]  payload  数据
/// [31]   checksum = sum(byte[0..30]) & 0xFF
/// ```
///
/// ### 应答（32 字节 Input 报告）
/// ```
/// [0..2] 回显 cmd / len / sub
/// [3..]  设备数据
/// [31]   checksum = sum(byte[0..30]) & 0xFF
/// ```
/// 成功判定：`resp[0..2] == req[0..2]` 且校验和正确。
///
/// ### 已验证命令
/// | cmd | len | 语义 | 应答数据 |
/// |---|---|---|---|
/// | `0x02` | 16 | 读设备信息 | `[7..8]=VID(05AC) [9..10]=PID(024F)` |
/// | `0x20` | 1  | 读电量 | `[3] = 电量%` |
/// | `0x05` | 16 | 写灯光 | 空（回显头即成功） |
/// | `0x10` | 28 | 主层键位块 0..20 | 空 |
/// | `0x12` | 28 | Fn 层键位块 0..20 | 空 |
/// | `0x03` | 4  | 主层单键写 | 空 |
/// | `0x0D` | 4  | Fn 层单键写 | 空 |
/// | `0x07` | 16 | 读系统配置 | 全 0（未能读出，待解） |
///
/// > 键盘 2.4G 休眠时通道完全无应答 —— 必须提示用户按任意键唤醒。
public final class GanssProtocol: @unchecked Sendable {

    public enum ProtocolError: Error, LocalizedError {
        case asleep            // 通道无应答（键盘休眠）
        case echoMismatch(String)
        case badChecksum
        case badResponse([UInt8])
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .asleep:
                return "键盘无应答（2.4G 无线已休眠）。请在键盘上按任意键唤醒，然后重试。"
            case .echoMismatch(let s):
                return "应答头不匹配：\(s)"
            case .badChecksum:
                return "应答校验和错误"
            case .badResponse(let b):
                return "应答格式异常: \(b.map { String(format: "%02x", $0) }.joined())"
            case .unsupported(let s):
                return s
            }
        }
    }

    public let transport: KeyboardTransport

    /// 命令字
    public enum Cmd {
        public static let deviceInfo: UInt8 = 0x02
        public static let readConfig: UInt8 = 0x07
        public static let writeConfig: UInt8 = 0x01
        public static let lightWrite: UInt8 = 0x05
        public static let keyLayerTop: UInt8 = 0x10    // 主层键位块
        public static let keyLayerFn: UInt8 = 0x12     // Fn 层键位块
        public static let keySingleTop: UInt8 = 0x03   // 主层单键
        public static let keySingleFn: UInt8 = 0x0D    // Fn 层单键
        public static let battery: UInt8 = 0x20
        public static let statusPoll: UInt8 = 0x1F
        public static let capability: UInt8 = 0x0F
    }

    public init(transport: KeyboardTransport) {
        self.transport = transport
    }

    // MARK: - 帧构造

    /// 构造 32 字节请求帧（含校验和）。
    public static func frame(cmd: UInt8, len: UInt8, sub: UInt8 = 0,
                             payload: [UInt8] = []) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 32)
        d[0] = cmd
        d[1] = len
        d[2] = sub
        let n = min(Int(len), payload.count, 32 - 3)
        if n > 0 { for i in 0..<n { d[3 + i] = payload[i] } }
        var sum: UInt8 = 0
        for i in 0..<31 { sum &+= d[i] }
        d[31] = sum
        return d
    }

    public static func checksum(_ d: [UInt8]) -> UInt8 {
        var s: UInt8 = 0
        for i in 0..<min(31, d.count) { s &+= d[i] }
        return s
    }

    /// 请求-应答。返回完整 32 字节应答。
    public func exchange(cmd: UInt8, len: UInt8, sub: UInt8 = 0,
                         payload: [UInt8] = [],
                         timeout: TimeInterval = 0.8) async throws -> [UInt8] {
        guard transport.isConnected else { throw KeyboardTransport.TransportError.notConnected }
        let req = Self.frame(cmd: cmd, len: len, sub: sub, payload: payload)
        let resp: [UInt8]
        do {
            resp = try await transport.request32(req, timeout: timeout)
        } catch KeyboardTransport.TransportError.timeout {
            throw ProtocolError.asleep
        }
        guard resp.count >= 32 else { throw ProtocolError.badResponse(resp) }
        guard resp[0] == cmd, resp[1] == len, resp[2] == sub else {
            throw ProtocolError.echoMismatch(
                String(format: "want %02x %02x %02x, got %02x %02x %02x",
                       cmd, len, sub, resp[0], resp[1], resp[2]))
        }
        guard resp[31] == Self.checksum(resp) else { throw ProtocolError.badChecksum }
        return resp
    }

    /// 纯写命令：只校验头回显，不要求数据。
    @discardableResult
    public func write(cmd: UInt8, len: UInt8, sub: UInt8 = 0,
                      payload: [UInt8] = []) async throws -> [UInt8] {
        try await exchange(cmd: cmd, len: len, sub: sub, payload: payload)
    }

    // MARK: - 已验证的读命令

    public struct DeviceInfo: Sendable {
        public let vid: Int
        public let pid: Int
        public let raw: [UInt8]
    }

    public func readDeviceInfo() async throws -> DeviceInfo {
        let r = try await exchange(cmd: Cmd.deviceInfo, len: 0x10)
        guard r.count > 10 else { throw ProtocolError.badResponse(r) }
        return DeviceInfo(vid: Int(r[7]) | (Int(r[8]) << 8),
                          pid: Int(r[9]) | (Int(r[10]) << 8),
                          raw: Array(r))
    }

    public func readBattery() async throws -> Int {
        let r = try await exchange(cmd: Cmd.battery, len: 0x01)
        guard r.count > 3 else { throw ProtocolError.badResponse(r) }
        return Int(r[3])
    }

    /// 探测键盘是否在线/唤醒。返回 false 表示休眠。
    public func probe() async -> Bool {
        do {
            _ = try await exchange(cmd: Cmd.deviceInfo, len: 0x10, timeout: 0.5)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 灯光（已真机验证）

    /// mode/brightness/speed/direction/colorful/color，单包下发。
    public func writeLighting(mode: Int, r: Int, g: Int, b: Int,
                              colorful: Bool, brightness: Int, speed: Int,
                              direction: Int) async throws {
        var payload = [UInt8](repeating: 0, count: 16)
        payload[0] = UInt8(mode & 0xFF)          // [3] mode
        if mode != 0 {
            payload[1] = UInt8(r & 0xFF)         // [4] R
            payload[2] = UInt8(g & 0xFF)         // [5] G
            payload[3] = UInt8(b & 0xFF)         // [6] B
            payload[8] = colorful ? 1 : 0        // [11]
            payload[9] = UInt8(brightness)       // [12]
            payload[10] = UInt8(speed)           // [13]
            payload[11] = UInt8(direction)       // [14]
        }
        payload[14] = 0xAA                       // [17]
        payload[15] = 0x55                       // [18]
        try await exchange(cmd: Cmd.lightWrite, len: 0x10, payload: payload)
    }

    // MARK: - 改键（4 字节记录，已验证类型 1/2/3/6）

    /// 4 字节键位记录。
    /// - default: `00 00 00 00`
    /// - key/combo: `02 mask usage 00`（mask = 修饰键位图 E0..E7 → 1..128）
    /// - disabled: `01 00 00 00`
    /// - media: `03 usageLo usageHi 00`
    /// - macro: `06 slot 00 00`
    public static func keyRecord(_ target: KeyTarget) -> [UInt8] {
        switch target {
        case .default:
            return [0, 0, 0, 0]
        case .disabled:
            return [0x01, 0, 0, 0]
        case .media(let usage):
            return [0x03, UInt8(usage & 0xFF), UInt8((usage >> 8) & 0xFF), 0]
        case .macro(let slot):
            return [0x06, UInt8(slot & 0xFF), 0, 0]
        case .key(let usage, let modifiers):
            var mask: UInt8 = 0
            for m in modifiers where (0xE0...0xE7).contains(m) {
                mask |= 1 << UInt8(m - 0xE0)
            }
            return [0x02, mask, UInt8(usage & 0xFF), 0]
        }
    }

    /// 单键写入（帧布局对齐上游 keymap_single_plan）。
    ///
    /// 32 字节帧：
    /// ```
    /// [0]    cmd       0x03 主层 / 0x0D Fn 层
    /// [1]    len       恒为 4
    /// [2]    key_index 目标键的 key_index（**放在 sub 字段**）
    /// [3..6] record    4 字节键位记录
    /// [31]   checksum
    /// ```
    public func writeSingleKey(index: Int, layer: KeyLayer, target: KeyTarget) async throws {
        guard (0...214).contains(index) else {
            throw ProtocolError.unsupported("键位索引超范围: \(index)")
        }
        let rec = Self.keyRecord(target)
        let cmd: UInt8 = layer == .top ? Cmd.keySingleTop : Cmd.keySingleFn
        try await exchange(cmd: cmd, len: 0x04, sub: UInt8(index & 0xFF),
                           payload: rec)
    }

    /// 整层写入：576 字节 = 144 条 × 4 字节，切成 21 块 × 28 字节。
    /// block 0..20，最后一块有效 16 字节；payload = 28 字节数据。
    public func writeFullLayer(layer: KeyLayer, table: [UInt8]) async throws {
        guard table.count == 576 else {
            throw ProtocolError.unsupported("整层表需 576 字节，实为 \(table.count)")
        }
        var data = table
        while data.count < 588 { data.append(0) }     // 21 × 28 = 588
        let cmd: UInt8 = layer == .top ? Cmd.keyLayerTop : Cmd.keyLayerFn
        for block in 0..<21 {
            let payload = Array(data[(block * 28)..<(block * 28 + 28)])
            let len: UInt8 = block == 20 ? 16 : 28
            try await exchange(cmd: cmd, len: len, sub: UInt8(block),
                               payload: Array(payload.prefix(Int(len))))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    // MARK: - 系统配置（读未解，写走 C1 64B 会话通道）

    /// 读系统配置。实测 cmd=0x07 各 sub 均返回全 0，暂视为未解。
    public func readSystemConfig() async throws -> SystemConfig {
        let r = try await exchange(cmd: Cmd.readConfig, len: 0x10)
        let d = Array(r[3..<19])
        // 若全 0 视为不可读，交由上层使用本地默认值
        if d.allSatisfy({ $0 == 0 }) { return SystemConfig.default }
        return SystemConfig(
            disableAltTab: d[0] != 0,
            disableAltF4: d[1] != 0,
            disableWin: d[2] != 0,
            fnSwitch: d[3] != 0,
            sleepTime: Int(d[4]),
            keyRespondTime: Int(d[6])
        )
    }

    /// 写系统配置：C1 64B 会话通道（`04 18` → `04 17` → `00 01`+数据 → `04 02` → `04 F0`）
    public func writeSystemConfig(_ cfg: SystemConfig) async throws {
        guard transport.connectedChannels.contains(.c1_64) else {
            throw ProtocolError.unsupported("系统配置写入需要 64 字节通道（当前未连接）")
        }
        try await transport.send(.c1_64, Self.c1([0x04, 0x18]))
        try await Task.sleep(nanoseconds: 40_000_000)
        try await transport.send(.c1_64, Self.c1([0x04, 0x17, 0x01, 0, 0, 0, 0, 0, 0x01]))
        try await Task.sleep(nanoseconds: 40_000_000)
        var data = [UInt8](repeating: 0, count: 64)
        data[0] = 0x00
        data[1] = 0x01
        data[2] = cfg.disableAltTab ? 1 : 0
        data[3] = cfg.disableAltF4 ? 1 : 0
        data[4] = cfg.disableWin ? 1 : 0
        data[5] = cfg.fnSwitch ? 1 : 0
        data[6] = UInt8(cfg.sleepTime)
        data[8] = UInt8(cfg.keyRespondTime)
        data[62] = 0x55
        data[63] = 0xAA
        try await transport.send(.c1_64, data)
        try await Task.sleep(nanoseconds: 60_000_000)
        try await transport.send(.c1_64, Self.c1([0x04, 0x02]))
        try await Task.sleep(nanoseconds: 40_000_000)
        try await transport.send(.c1_64, Self.c1([0x04, 0xF0]))
    }

    static func c1(_ head: [UInt8]) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 64)
        for (i, v) in head.enumerated() where i < 64 { d[i] = v }
        return d
    }
}

// MARK: - 数据类型

public enum KeyLayer: String, CaseIterable, Sendable {
    case top   // 主层（普通层）
    case fn    // Fn 层
    public var displayName: String { self == .top ? "主层" : "Fn 层" }
}

/// 改键目标
public enum KeyTarget: Equatable, Sendable {
    case `default`
    case disabled
    case key(usage: Int, modifiers: [Int])   // modifiers: HID usage 0xE0..0xE7
    case media(usage: Int)                   // Consumer page usage
    case macro(slot: Int)

    public var displayName: String {
        switch self {
        case .default: return "默认"
        case .disabled: return "禁用"
        case .key(let u, let m):
            let mods = m.map { Self.modName($0) }.joined(separator: "+")
            return mods.isEmpty ? String(format: "0x%02X", u) : mods + "+" + String(format: "0x%02X", u)
        case .media(let u): return String(format: "媒体 0x%03X", u)
        case .macro(let s): return "宏 #\(s)"
        }
    }

    static func modName(_ usage: Int) -> String {
        switch usage {
        case 0xE0: return "Ctrl"
        case 0xE1: return "Shift"
        case 0xE2: return "Alt"
        case 0xE3: return "Win"
        case 0xE4: return "RCtrl"
        case 0xE5: return "RShift"
        case 0xE6: return "RAlt"
        case 0xE7: return "RWin"
        default: return String(format: "0x%02X", usage)
        }
    }
}

public struct SystemConfig: Equatable, Sendable {
    public var disableAltTab: Bool
    public var disableAltF4: Bool
    public var disableWin: Bool
    public var fnSwitch: Bool
    public var sleepTime: Int      // 0=不休眠 1=1分钟 5=5分钟 30=30分钟
    public var keyRespondTime: Int // 1..5 档

    public init(disableAltTab: Bool = false, disableAltF4: Bool = false,
                disableWin: Bool = false, fnSwitch: Bool = false,
                sleepTime: Int = 0, keyRespondTime: Int = 3) {
        self.disableAltTab = disableAltTab
        self.disableAltF4 = disableAltF4
        self.disableWin = disableWin
        self.fnSwitch = fnSwitch
        self.sleepTime = sleepTime
        self.keyRespondTime = keyRespondTime
    }

    public static let `default` = SystemConfig()
}
