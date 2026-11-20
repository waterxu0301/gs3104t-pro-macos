import Foundation
import CoreGraphics

/// 从官方 `rgb-keyboard.xml` 解析出的键位布局与功能开关。
public struct KeyDef: Identifiable, Equatable, Sendable {
    public let id: Int            // key_index（1..124，带空洞）
    public let code: UInt8        // HID usage code
    public let name: String
    public let desc: String
    public let row: Int
    public let col: Int
    public let lightIndex: Int
    public let rect: CGRect
    public let fnLayerDisable: Bool
}

public struct KeyboardLayout: Sendable {
    public let keys: [KeyDef]
    public let colCount: Int
    public let rowCount: Int
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let image: String

    // 菜单开关（官方驱动能力矩阵）
    public let menuMacro: Bool
    public let menuLightMode: Bool
    public let menuSideLight: Bool
    public let menuUserLight: Bool
    public let menuCustomLight: Bool
    public let menuMusic: Bool
    public let menuScreen: Bool
    public let menuWirelessCustomLight: Bool

    // 灯光默认值
    public let defaultMode: Int
    public let defaultBrightness: Int
    public let defaultSpeed: Int
    public let brightnessMax: Int
    public let speedMax: Int
    public let cmdDelayMs: Int
    public let firmwareVersion: Int

    /// 解析官方布局 XML。
    public static func load(from data: Data) -> KeyboardLayout? {
        guard let doc = try? XMLDocument(data: data, options: []) else { return nil }
        guard let root = doc.rootElement() else { return nil }

        func children(_ parent: XMLElement, _ name: String) -> [XMLElement] {
            (parent.children ?? []).compactMap { c in
                (c as? XMLElement)?.name == name ? (c as? XMLElement) : nil
            }
        }
        func first(_ parent: XMLElement, _ name: String) -> XMLElement? {
            children(parent, name).first
        }
        func attr(_ e: XMLElement?, _ name: String, _ def: String = "") -> String {
            guard let e else { return def }
            return (e.attributes ?? []).first { $0.name == name }?.stringValue ?? def
        }
        func boolAttr(_ e: XMLElement?, _ name: String, _ def: Bool) -> Bool {
            guard let e else { return def }
            guard let v = (e.attributes ?? []).first(where: { $0.name == name })?.stringValue else { return def }
            return v == "1"
        }
        func intAttr(_ e: XMLElement?, _ name: String, _ def: Int) -> Int {
            Int(attr(e, name, "\(def)")) ?? def
        }

        let menu = first(root, "menu")
        let menuW = first(root, "menu_wireless")
        let fw = first(root, "firmware")
        let cmd = first(root, "cmd_delaytime")
        let light = first(root, "light")
        guard let kb = first(root, "Keyboard") else { return nil }

        var keys: [KeyDef] = []
        if let items = first(kb, "KeyItems") {
            for e in children(items, "key") {
                let rc = attr(e, "row_col", "0#0").split(separator: "#")
                let row = rc.count > 0 ? (Int(rc[0]) ?? 0) : 0
                let col = rc.count > 1 ? (Int(rc[1]) ?? 0) : 0
                let codeStr = attr(e, "code", "0x00").replacingOccurrences(of: "0x", with: "")
                let code = UInt8(codeStr, radix: 16) ?? 0
                let rect = CGRect(x: Double(attr(e, "rect_left", "0")) ?? 0,
                                  y: Double(attr(e, "rect_top", "0")) ?? 0,
                                  width: Double(attr(e, "rect_width", "0")) ?? 0,
                                  height: Double(attr(e, "rect_height", "0")) ?? 0)
                keys.append(KeyDef(
                    id: intAttr(e, "key_index", 0),
                    code: code,
                    name: attr(e, "name"),
                    desc: attr(e, "desc"),
                    row: row, col: col,
                    lightIndex: intAttr(e, "light_index", 0),
                    rect: rect,
                    fnLayerDisable: boolAttr(e, "fnlayer_disable", false)
                ))
            }
        }

        return KeyboardLayout(
            keys: keys,
            colCount: intAttr(kb, "col_count", 26),
            rowCount: intAttr(kb, "row_count", 6),
            canvasWidth: intAttr(kb, "width", 800),
            canvasHeight: intAttr(kb, "height", 300),
            image: attr(kb, "image"),
            menuMacro: boolAttr(menu, "macro", true),
            menuLightMode: boolAttr(menu, "light_mode", true),
            menuSideLight: boolAttr(menu, "sidelight", false),
            menuUserLight: boolAttr(menu, "user_light", true),
            menuCustomLight: boolAttr(menu, "custom_light", true),
            menuMusic: boolAttr(menu, "music", true),
            menuScreen: boolAttr(menu, "screen", false),
            menuWirelessCustomLight: boolAttr(menuW, "custom_light", false),
            defaultMode: intAttr(light, "default_mode", 11),
            defaultBrightness: intAttr(light, "default_brightness", 5),
            defaultSpeed: intAttr(light, "default_speed", 3),
            brightnessMax: intAttr(light, "brightness_max", 5),
            speedMax: intAttr(light, "speed_max", 5),
            cmdDelayMs: intAttr(cmd, "value", 35),
            firmwareVersion: intAttr(fw, "version", 0)
        )
    }

    public static func loadBundled() -> KeyboardLayout? {
        // 1) app bundle Resources
        if let url = Bundle.main.url(forResource: "rgb-keyboard", withExtension: "xml"),
           let data = try? Data(contentsOf: url),
           let l = load(from: data) { return l }
        // 2) 开发期：相对当前工作目录
        let candidates = [
            "Resources/rgb-keyboard.xml",
            "APP/Resources/rgb-keyboard.xml",
            "../Resources/rgb-keyboard.xml"
        ]
        for c in candidates {
            if let data = FileManager.default.contents(atPath: c), let l = load(from: data) { return l }
        }
        return nil
    }
}

public struct KeyBinding: Equatable, Identifiable, Sendable {
    public var id: Int { keyId * 10 + (layer == .top ? 0 : 1) }
    public var keyId: Int
    public var layer: KeyLayer
    public var target: KeyTarget

    public init(keyId: Int, layer: KeyLayer, target: KeyTarget = .default) {
        self.keyId = keyId
        self.layer = layer
        self.target = target
    }
}

// MARK: - 宏

public struct MacroAction: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case keyDown, keyUp, mouseDown, mouseUp, delay
    }
    public var id = UUID()
    public var kind: Kind
    public var code: Int      // 键码 / 鼠标键
    public var delayMs: Int   // delay 动作使用

    public init(kind: Kind, code: Int = 0, delayMs: Int = 0) {
        self.kind = kind
        self.code = code
        self.delayMs = delayMs
    }
}

public struct Macro: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var actions: [MacroAction]
    public var playTimes: Int      // 1..255，0 = 循环
    public var delayType: Int      // 0=记录间隔 1=不记录 2=默认间隔

    public init(name: String, actions: [MacroAction] = [], playTimes: Int = 1, delayType: Int = 0) {
        self.name = name
        self.actions = actions
        self.playTimes = playTimes
        self.delayType = delayType
    }
}

// MARK: - 灯光

public struct LightingState: Equatable, Sendable {
    public var mode: Int
    public var brightness: Int
    public var speed: Int
    public var direction: Int      // 0=上 1=右 2=下 3=左
    public var color: Int          // 0xRRGGBB
    public var colorful: Bool

    public init(mode: Int = 11, brightness: Int = 5, speed: Int = 3,
                direction: Int = 0, color: Int = 0xFFFFFF, colorful: Bool = true) {
        self.mode = mode
        self.brightness = brightness
        self.speed = speed
        self.direction = direction
        self.color = color
        self.colorful = colorful
    }
}

/// 灯光模式表（官方语言文件 501-540 段，分 A/B 两组共 38 项 + 实时灯效 9 项）
public struct LightMode: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let group: String
}

public enum LightModes {
    public static let realtime: [LightMode] = [
        .init(id: 0, name: "静态恒亮", group: "实时灯效"),
        .init(id: 1, name: "繁星点点", group: "实时灯效"),
        .init(id: 2, name: "漫天飞舞", group: "实时灯效"),
        .init(id: 3, name: "动态呼吸", group: "实时灯效"),
        .init(id: 4, name: "彩泉涌动", group: "实时灯效"),
        .init(id: 5, name: "多彩纵横", group: "实时灯效"),
        .init(id: 6, name: "随波逐流", group: "实时灯效"),
        .init(id: 7, name: "峰回路转", group: "实时灯效"),
        .init(id: 8, name: "关闭灯光", group: "实时灯效")
    ]

    public static let themeA: [LightMode] = [
        .init(id: 1, name: "引力波动", group: "主题灯效"),
        .init(id: 2, name: "电子跃迁", group: "主题灯效"),
        .init(id: 3, name: "穿越虫洞", group: "主题灯效"),
        .init(id: 4, name: "空间泡沫", group: "主题灯效"),
        .init(id: 5, name: "重力喷泉", group: "主题灯效"),
        .init(id: 6, name: "太阳风暴", group: "主题灯效"),
        .init(id: 7, name: "离子推进", group: "主题灯效"),
        .init(id: 8, name: "偏振光波", group: "主题灯效"),
        .init(id: 9, name: "时间沙漏", group: "主题灯效"),
        .init(id: 10, name: "光粒打击", group: "主题灯效"),
        .init(id: 11, name: "能量湮灭", group: "主题灯效"),
        .init(id: 12, name: "超膜广播", group: "主题灯效"),
        .init(id: 13, name: "时空扭曲", group: "主题灯效"),
        .init(id: 14, name: "电磁弹射", group: "主题灯效"),
        .init(id: 15, name: "粒子加速", group: "主题灯效"),
        .init(id: 16, name: "恒星纪元", group: "主题灯效"),
        .init(id: 17, name: "量子涨落", group: "主题灯效"),
        .init(id: 18, name: "关闭背光", group: "主题灯效")
    ]

    public static let themeB: [LightMode] = [
        .init(id: 1, name: "静态恒亮", group: "经典灯效"),
        .init(id: 2, name: "单点亮", group: "经典灯效"),
        .init(id: 3, name: "单熄灭", group: "经典灯效"),
        .init(id: 4, name: "繁星点点", group: "经典灯效"),
        .init(id: 5, name: "漫天飞雪", group: "经典灯效"),
        .init(id: 6, name: "百花争艳", group: "经典灯效"),
        .init(id: 7, name: "动态呼吸", group: "经典灯效"),
        .init(id: 8, name: "光谱循环", group: "经典灯效"),
        .init(id: 9, name: "彩泉涌动", group: "经典灯效"),
        .init(id: 10, name: "多彩纵横", group: "经典灯效"),
        .init(id: 11, name: "随波逐流", group: "经典灯效"),
        .init(id: 12, name: "峰回路转", group: "经典灯效"),
        .init(id: 13, name: "一触即发", group: "经典灯效"),
        .init(id: 14, name: "一石二鸟", group: "经典灯效"),
        .init(id: 15, name: "涟漪扩散", group: "经典灯效"),
        .init(id: 16, name: "川流不息", group: "经典灯效"),
        .init(id: 17, name: "重峦叠嶂", group: "经典灯效"),
        .init(id: 18, name: "斜风细雨", group: "经典灯效"),
        .init(id: 19, name: "来回穿梭", group: "经典灯效"),
        .init(id: 20, name: "关闭背光", group: "经典灯效")
    ]

    public static let all: [LightMode] = realtime + themeA + themeB

    public static func name(id: Int) -> String {
        all.first { $0.id == id }?.name ?? "模式 \(id)"
    }
}

// MARK: - 配置档

public struct Profile: Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var lighting: LightingState
    public var bindings: [KeyBinding]
    public init(id: Int, name: String,
                lighting: LightingState = LightingState(),
                bindings: [KeyBinding] = []) {
        self.id = id
        self.name = name
        self.lighting = lighting
        self.bindings = bindings
    }
}


// MARK: - 双系统键位模式

/// 键盘硬件可在 Windows / macOS 模式间切换。
/// 同一 HID usage 在两套系统下语义不同（0xE3 在 Windows 是 Win、在 macOS 是 ⌘），
/// 官方实物丝印即为双标注（WIN 键旁印 ⌘、ALT 键旁印 ⌥）。
public enum KeyboardMode: String, CaseIterable, Identifiable, Sendable {
    case windows
    case mac
    public var id: String { rawValue }
    public var displayName: String { self == .windows ? "Windows" : "macOS" }

    /// 差异键：两套模式下显示名不同的键。
    ///
    /// 硬件用 Fn+S 切换模式；切到 macOS 后 **⌘ 与 ⌥ 位置互换**，
    /// 使左下角成为标准 Mac 布局 `⌃ ⌥ ⌘`（Windows 下是 `Ctrl Win Alt`）。
    /// 右侧按对称映射为 `⌘ Fn ⌥ ⌃`。
    public func label(for name: String) -> String {
        switch (self, name) {
        // ---- 左下角 ----
        case (.mac, "Win_L"):         return "\u{2325}"   // 位置2 → ⌥（互换后）
        case (.mac, "Alt_L"):         return "\u{2318}"   // 位置3 → ⌘（互换后）
        case (.windows, "Win_L"):     return "Win"
        case (.windows, "Alt_L"):     return "Alt"
        // ---- 右下角 ----
        case (.mac, "Alt_R"):         return "\u{2318}"   // 右端外侧 → ⌘
        case (.mac, "APP"):           return "\u{2325}"   // → ⌥
        case (.mac, "Ctrl_R"):        return "\u{2303}"   // → ⌃
        case (.windows, "Alt_R"):     return "Alt"
        case (.windows, "APP"):       return "APP"
        // ---- Control：两套都有，仅符号不同 ----
        case (.mac, "Ctrl_L"):        return "\u{2303}"
        case (.windows, "Ctrl_L"):    return "Ctrl"
        default: return name
        }
    }

    /// 该键在两套模式下是否显示不同（用于视觉标记）
    public static func isDifferential(_ name: String) -> Bool {
        KeyboardMode.windows.label(for: name) != KeyboardMode.mac.label(for: name)
    }
}
