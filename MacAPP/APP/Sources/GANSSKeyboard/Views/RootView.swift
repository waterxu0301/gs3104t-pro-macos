import SwiftUI

/// 即开即用：点红灯（关闭窗口）即**彻底退出进程**，
/// 不留后台、不留 Dock/状态栏残留。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    func applicationWillTerminate(_ notification: Notification) {
        // 退出前清理 HID 资源（进程退出本会由系统回收，这里保证干净）
        NotificationCenter.default.post(name: .appWillTerminate, object: nil)
    }
}

extension Notification.Name {
    static let appWillTerminate = Notification.Name("appWillTerminate")
}

@main
struct GANSSKeyboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        if ProcessInfo.processInfo.environment["GANSS_CLI"] == "1" {
            Task { await HeadlessTest.run() }
        }
    }

    var body: some Scene {
        WindowGroup("GANSS GS3104T-PRO 键盘助手") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    if ProcessInfo.processInfo.environment["GANSS_CLI"] != "1" {
                        model.start()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .home

    var body: some View {
        // 用 HSplitView 而非 NavigationSplitView：
        // NavigationSplitView 的 sidebar 列会干预子视图的点击分发，
        // 导致自绘按钮栏整排点不动（实测）。HSplitView 是 AppKit NSSplitView 包装，
        // 支持拖拽分栏且不拦截子视图交互。
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 300)

            detail
                .frame(minWidth: 640)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SidebarItem.all) { item in
                        SidebarRow(item: item,
                                   isSelected: selection == item) {
                            selection = item
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            ConnectionBadge()
                .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detail: some View {
        let current = selection ?? .home
        return Group {
            if current == .home { HomeView() }
            else if current == .profiles { ProfilesView() }
            else if current == .remap { RemapView() }
            else if current == .macros { MacrosView() }
            else if current == .light { LightingView() }
            else if current == .customLight { CustomLightView() }
            else if current == .music { MusicView() }
            else if current == .system { SystemConfigView() }
            else { DiagnosticsView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarItem: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String

    static let home = SidebarItem(id: "home", title: "主页", icon: "keyboard")
    static let profiles = SidebarItem(id: "profiles", title: "我的专属配置", icon: "person.crop.circle")
    static let remap = SidebarItem(id: "remap", title: "按键自定义", icon: "square.grid.3x3")
    static let macros = SidebarItem(id: "macros", title: "宏管理器", icon: "record.circle")
    static let light = SidebarItem(id: "light", title: "灯光模式", icon: "lightbulb.max")
    static let customLight = SidebarItem(id: "customLight", title: "自定义灯光", icon: "paintbrush.pointed")
    static let music = SidebarItem(id: "music", title: "音乐律动", icon: "music.note")
    static let system = SidebarItem(id: "system", title: "系统配置", icon: "gearshape")
    static let diagnostics = SidebarItem(id: "diagnostics", title: "连接诊断", icon: "stethoscope")

    static let all: [SidebarItem] = [.home, .profiles, .remap, .macros, .light,
                                     .customLight, .music, .system, .diagnostics]
}

/// 侧边栏行：自绘按钮，避免 List 的键盘导航/type-ahead 抢占按键。
struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(item.title, systemImage: item.icon)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .contentShape(Rectangle())          // 明确整块为可点击区域
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .lineLimit(2)
            }
            if let b = model.battery {
                Label("\(b)%", systemImage: "battery.75")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch model.connection {
        case .connected: return .green
        case .disconnected: return .red
        case .asleep: return .orange
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch model.connection {
        case .idle: return "正在查找设备…"
        case .connected(let d): return "已连接 · \(d)"
        case .disconnected: return "未连接键盘"
        case .asleep: return "键盘休眠，请按键唤醒"
        }
    }
}
