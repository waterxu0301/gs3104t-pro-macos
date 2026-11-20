import SwiftUI

// MARK: - 主页

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let err = model.lastError {
                    ErrorBanner(message: err) { model.lastError = nil }
                }
                if let n = model.notice {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(n)
                        Spacer()
                        Button("清除") { model.notice = nil }
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if model.connection == .asleep {
                    awakeBanner
                }
                if model.needsInputPermission {
                    permissionBanner
                }
                deviceCard
                quickActions
                // 键盘模式切换（对应硬件 Win/Mac 拨杆）：决定修饰键显示为 Win/Alt 还是 ⌘/⌥
                HStack(spacing: 10) {
                    Text("键盘模式")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $model.keyboardMode) {
                        ForEach(KeyboardMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                    Spacer(minLength: 8)
                    Text(modeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if !model.layout.keys.isEmpty {
                    KeyboardPreviewView(bindings: model.keyBindings,
                                        layer: .top,
                                        colors: [:],
                                        pressed: model.previewMode ? model.pressedUsages : [])
                }

                // 按键提示置于键盘图下方，固定高度占位（避免内容变化推挤键盘图）。
                // 用 maxWidth 而非 Spacer、去掉 textSelection：两者在高频更新下
                // 会反复触发约束重算，与 hitTest 并发时曾导致 Auto Layout 崩溃。
                HStack(spacing: 10) {
                    Toggle("预览模式", isOn: $model.previewMode)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text(model.previewMode ? "按下键位会高亮 · 仅视觉预览，不下发任何指令"
                                          : "预览模式已关闭")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(pressedText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(model.pressedUsages.isEmpty ? Color.secondary : Color.blue)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)          // 固定高度 → 键盘图不随内容浮动
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GS3104T-PRO")
                .font(.largeTitle.bold())
            Text("macOS 即开即用驱动 · 协议真机验证于 2.4G 通道")
                .foregroundStyle(.secondary)
        }
    }

    private var awakeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("键盘处于 2.4G 休眠").fontWeight(.semibold)
                Text("请在 GS3104T-PRO 上按任意键唤醒 —— 程序会自动检测并读取状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("立即探测") {
                Task { await model.refreshAfterWake() }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var deviceCard: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("连接状态").foregroundStyle(.secondary)
                    Text(statusText)
                }
                GridRow {
                    Text("电量").foregroundStyle(.secondary)
                    Text(model.battery.map { "\($0)%" } ?? "—")
                }
                GridRow {
                    Text("设备 VID:PID").foregroundStyle(.secondary)
                    Text(model.deviceInfo.map { String(format: "%04X:%04X", $0.vid, $0.pid) } ?? "—")
                }
                GridRow {
                    Text("配置通道").foregroundStyle(.secondary)
                    Text(channelText)
                }
                GridRow {
                    Text("按键响应时间").foregroundStyle(.secondary)
                    Text("\(model.systemConfig.keyRespondTime) 档")
                }
            }
            .padding(4)
        }
    }

    private var modeHint: String {
        // 模式由键盘固件切换：Fn+A → Windows，Fn+S → macOS（APP 无法远程改写）
        if model.keyboardMode == .mac {
            return "macOS 模式 · Fn+S 切换（Fn+A → Windows）"
        } else {
            return "Windows 模式 · Fn+A 切换（Fn+S → macOS）"
        }
    }

    /// 输入监控权限引导：即开即用需要明确告知用户如何授权
    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("缺少「输入监控」权限，实时按键预览不可用")
                    .fontWeight(.semibold)
                Text("系统设置 → 隐私与安全性 → 输入监控 → 添加本 App 并开启，然后**重新打开 App**。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var pressedText: String {
        guard model.previewMode else { return "—" }
        let usages = model.pressedUsages.sorted()
        if usages.isEmpty {
            return "在键盘上按键，此处会实时显示键值"
        }
        return "按下: " + usages.map { String(format: "0x%02X", $0) }.joined(separator: " ")
    }

    private var channelText: String {
        let ch = model.transport.connectedChannels
        if ch.isEmpty { return "无" }
        // MI_03 是真正的命令通道，排在前面
        let ordered = ([KeyboardTransport.ChannelKind.c2_32,
                       KeyboardTransport.ChannelKind.c1_64].filter { ch.contains($0) })
        return ordered.map { $0 == .c2_32 ? "MI_03 · 32B（命令通道）" : "MI_04 · 64B（状态包）" }
            .joined(separator: "，")
    }

    private var statusText: String {
        switch model.connection {
        case .idle: return "正在查找设备…"
        case .connected(let d): return d
        case .disconnected: return "未连接（请插上键盘或接收器）"
        case .asleep: return "键盘休眠（按任意键唤醒）"
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button {
                model.diagnose()
            } label: {
                Label("连接诊断", systemImage: "stethoscope")
            }
            Button {
                model.refreshBattery()
            } label: {
                Label("读取电量", systemImage: "battery.100")
            }
            Button {
                Task { await model.refreshAfterWake() }
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy)
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - 错误横幅

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .textSelection(.enabled)
            Spacer()
            Button("知道了", action: onDismiss)
        }
        .padding(10)
        .foregroundStyle(.orange)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 系统配置

struct SystemConfigView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("按键响应时间（5 档）") {
                Picker("档位", selection: $model.systemConfig.keyRespondTime) {
                    ForEach(1...5, id: \.self) { i in
                        Text("\(i) 档").tag(i)
                    }
                }
                .pickerStyle(.segmented)
                Text(describeDelay(model.systemConfig.keyRespondTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("键盘休眠时间") {
                Picker("休眠", selection: $model.systemConfig.sleepTime) {
                    Text("不休眠").tag(0)
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("30 分钟").tag(30)
                }
            }

            Section("禁用按键") {
                Toggle("禁用 Windows 键", isOn: $model.systemConfig.disableWin)
                Toggle("禁用 Alt + Tab", isOn: $model.systemConfig.disableAltTab)
                Toggle("禁用 Alt + F4", isOn: $model.systemConfig.disableAltF4)
            }

            Section("Fn 层") {
                Toggle("Fn 开关功能（切换式）", isOn: $model.systemConfig.fnSwitch)
            }

            Section {
                Text("写入走 64B 会话通道（04 18 → 04 17 → 00 01 → 04 02 → 04 F0）；"
                     + "读取（00 07）目前返回全 0，属未解协议项，回显不代表字段已读回。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("应用到键盘") { model.applySystemConfig() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                    Button("尝试读取") { model.readSystemConfig() }
                        .disabled(model.busy)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
    }

    private func describeDelay(_ level: Int) -> String {
        switch level {
        case 1: return "一档：有线约 2-3ms，2.4G 约 5-6ms"
        case 2: return "二档：有线约 5-6ms，2.4G 约 7-9ms"
        case 3: return "三档：有线约 8-9ms，2.4G 约 10-12ms"
        case 4: return "四档：有线约 13-14ms，2.4G 约 15-17ms"
        case 5: return "五档：有线约 17-18ms，2.4G 约 19-21ms"
        default: return "参数可能因轴体与环境干扰变化；过低可能引起连击。"
        }
    }
}

// MARK: - 诊断

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("连接诊断与协议日志").font(.title2.bold())
                Spacer()
                Button("运行诊断") { model.diagnose() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                Button("清空日志") { model.log.removeAll() }
            }

            if let err = model.lastError {
                ErrorBanner(message: err) { model.lastError = nil }
            }

            GroupBox("通道状态") {
                HStack(spacing: 16) {
                    channelChip("MI_03 · 32B 命令通道（已验证）", .c2_32)
                    channelChip("MI_04 · 64B（仅回状态包）", .c1_64)
                }
                .padding(4)
            }

            GroupBox("原始收发日志") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.log) { e in
                                HStack(spacing: 8) {
                                    Text(timeString(e.date))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 96, alignment: .leading)
                                    Text(e.direction)
                                        .font(.system(.caption2, design: .monospaced).bold())
                                        .foregroundStyle(dirColor(e.direction))
                                        .frame(width: 24)
                                    Text(e.channel)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 60, alignment: .leading)
                                    Text(e.hex)
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .id(e.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: model.log.count) { _ in
                        if let last = model.log.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .padding(24)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func timeString(_ d: Date) -> String {
        Self.timeFormatter.string(from: d)
    }

    private func dirColor(_ d: String) -> Color {
        if d == "TX" { return .blue }
        if d == "RX" { return .green }
        return .red
    }

    private func channelChip(_ title: String, _ kind: KeyboardTransport.ChannelKind) -> some View {
        let on = model.transport.connectedChannels.contains(kind)
        return HStack {
            Circle().fill(on ? Color.green : Color.gray.opacity(0.4)).frame(width: 8, height: 8)
            Text(title).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }
}

// MARK: - 配置档（本地保存/应用，设备侧切换命令未验证）

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("我的专属配置").font(.title2.bold())
            Text("配置档保存在本机（灯光参数 + 改键表），点「应用」一次性下发到键盘。"
                 + "官方驱动的设备侧配置档切换命令尚未真机验证，故不提供在线切换。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let err = model.lastError {
                ErrorBanner(message: err) { model.lastError = nil }
            }
            if let n = model.notice {
                Text(n).font(.callout).foregroundStyle(.green)
            }

            HStack {
                TextField("新配置档名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("保存当前设置") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    var p = model.profiles.first { $0.name == n } ?? Profile(id: model.profiles.count, name: n)
                    p.lighting = model.lighting
                    p.bindings = model.keyBindings
                    if let i = model.profiles.firstIndex(where: { $0.name == n }) {
                        model.profiles[i] = p
                    } else {
                        model.profiles.append(p)
                    }
                    name = ""
                    model.notice = "已保存配置档「\(n)」"
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            List(model.profiles) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.name).fontWeight(.medium)
                        Text("灯光模式 \(p.lighting.mode) · 亮度 \(p.lighting.brightness) · \(p.bindings.filter { $0.target != .default }.count) 处改键")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("载入") {
                        model.lighting = p.lighting
                        for i in model.keyBindings.indices {
                            if let b = p.bindings.first(where: { $0.id == model.keyBindings[i].id }) {
                                model.keyBindings[i] = b
                            }
                        }
                        model.notice = "已载入「\(p.name)」到编辑器，点「应用」下发"
                    }
                    Button("应用到键盘") {
                        model.lighting = p.lighting
                        for i in model.keyBindings.indices {
                            if let b = p.bindings.first(where: { $0.id == model.keyBindings[i].id }) {
                                model.keyBindings[i] = b
                            }
                        }
                        model.applyLighting()
                        model.applyFullLayer(layer: .top)
                        model.applyFullLayer(layer: .fn)
                    }
                    .disabled(model.busy)
                    Button(role: .destructive) {
                        model.profiles.removeAll { $0.id == p.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            .listStyle(.inset)
        }
        .padding(24)
    }
}
