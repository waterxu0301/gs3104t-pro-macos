import Foundation
import SwiftUI
import Combine

/// 应用全局状态：连接、协议、配置数据、UI 导航。
@MainActor
public final class AppModel: ObservableObject {

    public enum Connection: Equatable {
        case idle
        case connected(String)
        case disconnected(String)
        case asleep

        public var isReady: Bool { if case .connected = self { return true }; return false }
    }

    @Published public var connection: Connection = .idle
    @Published public var log: [KeyboardTransport.LogEntry] = []
    @Published public var lastError: String?
    @Published public var notice: String?
    @Published public var busy = false

    @Published public var layout: KeyboardLayout
    @Published public var battery: Int?
    @Published public var deviceInfo: GanssProtocol.DeviceInfo?
    @Published public var systemConfig: SystemConfig = .default
    @Published public var lighting: LightingState

    @Published public var keyBindings: [KeyBinding] = []
    @Published public var profiles: [Profile] = []
    @Published public var macros: [Macro] = []
    @Published public var perKeyColors: [Int: Int] = [:]

    /// 供 CLI 自检订阅原始收发日志。
    public var externalLog: ((KeyboardTransport.LogEntry) -> Void)?

    /// 当前按下的 HID usage（首页预览图实时高亮）
    @Published public var pressedUsages: Set<UInt8> = []
    /// 预览模式：开启时同步高亮按键（仅视觉反馈，不下发任何指令）
    @Published public var previewMode = true
    /// 键盘当前所处模式（硬件切换）：决定修饰键显示为 Win/Alt 还是 ⌘/⌥
    @Published public var keyboardMode: KeyboardMode = .mac
    /// 缺少「输入监控」权限（实时按键预览不可用）
    @Published public var needsInputPermission = false

    // MARK: - 写入保护
    /// 启动/连接阶段保护：从 `start()` 到首次连接读取完成期间拒绝一切写入。
    /// 原则：启动、USB/2.4G 连接、休眠唤醒恢复阶段 100% 只读
    /// （仅允许 02 设备信息与 20 电量查询），任何写入必须由用户显式交互触发。
    private var startupPhase = true
    /// 最近一次用户显式交互时间（用于区分「用户点击」与「自动触发」）
    private var lastUserAction: Date?
    /// 写入审计日志：每次拒绝或放行都记录，便于诊断
    @Published public var writeAudit: [String] = []
    private let keyMonitor = KeyMonitor()

    public let transport = KeyboardTransport()
    public let proto: GanssProtocol
    private var wakeTask: Task<Void, Never>?

    public init() {
        let loaded = KeyboardLayout.loadBundled() ?? KeyboardLayout(
            keys: [], colCount: 26, rowCount: 6, canvasWidth: 800, canvasHeight: 300,
            image: "", menuMacro: true, menuLightMode: true, menuSideLight: false,
            menuUserLight: true, menuCustomLight: true, menuMusic: true, menuScreen: false,
            menuWirelessCustomLight: false, defaultMode: 11, defaultBrightness: 5,
            defaultSpeed: 3, brightnessMax: 5, speedMax: 5, cmdDelayMs: 35, firmwareVersion: 120
        )
        layout = loaded
        lighting = LightingState(mode: loaded.defaultMode,
                                 brightness: loaded.defaultBrightness,
                                 speed: loaded.defaultSpeed)
        proto = GanssProtocol(transport: transport)
        var bindings: [KeyBinding] = []
        for k in loaded.keys {
            bindings.append(KeyBinding(keyId: k.id, layer: .top, target: .default))
            bindings.append(KeyBinding(keyId: k.id, layer: .fn, target: .default))
        }
        keyBindings = bindings

        transport.onLog = { [weak self] entry in
            Task { @MainActor in
                guard let self else { return }
                self.externalLog?(entry)
                self.log.append(entry)
                if self.log.count > 400 { self.log.removeFirst(self.log.count - 400) }
            }
        }
        transport.onDeviceChange = { [weak self] connected, detail in
            Task { @MainActor in
                guard let self else { return }
                if connected {
                    self.connection = .connected(detail)
                    await self.onConnected()
                } else {
                    self.connection = .disconnected(detail)
                    self.battery = nil
                    self.deviceInfo = nil
                }
            }
        }
    }

    public func start() {
        transport.start()
        keyMonitor.onChange = { [weak self] usages in
            Task { @MainActor in self?.pressedUsages = usages }
        }
        keyMonitor.start()
        needsInputPermission = !keyMonitor.isAuthorized
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.needsInputPermission = !self.keyMonitor.isAuthorized
        }

        // 退出时清理（配合 AppDelegate.applicationShouldTerminateAfterLastWindowClosed）
        NotificationCenter.default.addObserver(forName: .appWillTerminate,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.shutdown()
        }
    }

    /// 进程退出前的资源清理
    public func shutdown() {
        keyMonitor.stop()
        transport.stop()
        wakeTask?.cancel()
    }

    // MARK: - 连接后初始化 + 休眠监测

    private func onConnected() async {
        if await proto.probe() {
            await refreshAfterWake()
        } else {
            connection = .asleep
            notice = "键盘处于 2.4G 休眠状态，请按任意键唤醒"
            startWakeWatch()
        }
    }

    /// 键盘唤醒后读取状态。
    public func refreshAfterWake() async {
        do {
            deviceInfo = try await proto.readDeviceInfo()
            battery = try await proto.readBattery()
            connection = .connected(String(format: "VID %04X PID %04X · 电量 %d%%",
                                           deviceInfo?.vid ?? 0, deviceInfo?.pid ?? 0, battery ?? 0))
            releaseStartupGuard()
            notice = nil
            lastError = nil
        } catch GanssProtocol.ProtocolError.asleep {
            connection = .asleep
            notice = "键盘无应答，请按任意键唤醒"
            startWakeWatch()
        } catch {
            record(error)
        }
    }

    /// 轮询等待键盘唤醒（每 1.5s 探测一次）。
    private func startWakeWatch() {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                if case .asleep = self.connection {
                    if await self.proto.probe() {
                        self.notice = "键盘已唤醒，正在读取状态…"
                        await self.refreshAfterWake()
                        return
                    }
                } else { return }
            }
        }
    }

    // MARK: - 写入守卫

    /// 由所有 `Button` 回调在调用 `apply*` 前调用，标记「用户显式操作」。
    public func markUserAction() {
        lastUserAction = Date()
    }

    /// 写入前的统一检查：启动阶段一律拒绝；仅放行用户显式触发的写入。
    private func guardWrite(_ what: String) -> Bool {
        if startupPhase {
            let msg = "⚠️ 启动保护：拒绝下发 \(what)（启动/连接阶段只读）"
            writeAudit.append(msg)
            notice = msg
            NSLog("[WriteGuard] %@", msg)
            return false
        }
        guard let last = lastUserAction, Date().timeIntervalSince(last) < 30 else {
            let msg = "⚠️ 拒绝下发 \(what)：非用户显式操作触发"
            writeAudit.append(msg)
            NSLog("[WriteGuard] %@", msg)
            return false
        }
        writeAudit.append("✅ 放行 \(what)（用户操作）")
        return true
    }

    /// 启动保护解除（首次成功读取状态后）
    private func releaseStartupGuard() {
        startupPhase = false
    }

    // MARK: - 操作入口

    public func run(_ label: String, _ body: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task {
            defer { Task { @MainActor in self.busy = false } }
            do {
                try await body()
                notice = "\(label) 完成"
            } catch GanssProtocol.ProtocolError.asleep {
                connection = .asleep
                notice = nil
                lastError = GanssProtocol.ProtocolError.asleep.localizedDescription
                startWakeWatch()
            } catch {
                record(error, label: label)
            }
        }
    }

    public func record(_ error: Error, label: String? = nil) {
        let prefix = label.map { "\($0)：" } ?? ""
        lastError = prefix + error.localizedDescription
    }

    // MARK: - 灯光

    public func applyLighting() {
        guard guardWrite("灯光 05") else { return }
        let l = lighting
        run("写入灯光") { [weak self] in
            guard let self else { return }
            let hex = l.color
            try await self.proto.writeLighting(
                mode: l.mode,
                r: (hex >> 16) & 0xFF, g: (hex >> 8) & 0xFF, b: hex & 0xFF,
                colorful: l.colorful,
                brightness: l.brightness, speed: l.speed, direction: l.direction)
        }
    }

    // MARK: - 改键

    /// 单键下发（真机验证通路）。
    public func applySingleKey(_ binding: KeyBinding) {
        guard guardWrite("单键 03/0D") else { return }
        guard let key = layout.keys.first(where: { $0.id == binding.keyId }) else { return }
        run("写入 \(key.name)") { [weak self] in
            guard let self else { return }
            try await self.proto.writeSingleKey(index: key.id, layer: binding.layer,
                                                target: binding.target)
        }
    }

    /// 整层下发（21 块）。
    public func applyFullLayer(layer: KeyLayer) {
        guard guardWrite("整层 10/12") else { return }
        run("写入\(layer.displayName)整层") { [weak self] in
            guard let self else { return }
            var table = [UInt8](repeating: 0, count: 576)
            for b in self.keyBindings where b.layer == layer {
                guard let idx = self.layout.keys.firstIndex(where: { $0.id == b.keyId }) else { continue }
                let rec = GanssProtocol.keyRecord(b.target)
                let off = b.keyId * 4
                if off + 4 <= 576 { for i in 0..<4 { table[off + i] = rec[i] } }
                _ = idx
            }
            table[574] = 0xAA
            table[575] = 0x55
            try await self.proto.writeFullLayer(layer: layer, table: table)
        }
    }

    /// 恢复整层默认。
    public func resetLayer(layer: KeyLayer) {
        guard guardWrite("整层重置 10/12") else { return }
        run("恢复\(layer.displayName)默认") { [weak self] in
            guard let self else { return }
            var table = [UInt8](repeating: 0, count: 576)
            table[574] = 0xAA
            table[575] = 0x55
            try await self.proto.writeFullLayer(layer: layer, table: table)
            for i in self.keyBindings.indices where self.keyBindings[i].layer == layer {
                self.keyBindings[i].target = .default
            }
        }
    }

    // MARK: - 系统配置

    public func applySystemConfig() {
        guard guardWrite("系统配置 04 18") else { return }
        run("写入系统配置") { [weak self] in
            guard let self else { return }
            try await self.proto.writeSystemConfig(self.systemConfig)
        }
    }

    public func readSystemConfig() {
        run("读取系统配置") { [weak self] in
            guard let self else { return }
            self.systemConfig = try await self.proto.readSystemConfig()
        }
    }

    // MARK: - 诊断

    public func diagnose() {
        run("连接诊断") { [weak self] in
            guard let self else { return }
            guard !self.transport.connectedChannels.isEmpty else {
                throw KeyboardTransport.TransportError.notConnected
            }
            self.deviceInfo = try await self.proto.readDeviceInfo()
            self.battery = try await self.proto.readBattery()
            self.systemConfig = try await self.proto.readSystemConfig()
        }
    }

    public func refreshBattery() {
        run("读取电量") { [weak self] in
            guard let self else { return }
            self.battery = try await self.proto.readBattery()
        }
    }
}
