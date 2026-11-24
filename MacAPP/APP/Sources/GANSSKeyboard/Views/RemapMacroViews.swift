import SwiftUI

/// 键盘布局预览：按官方 rgb-keyboard.xml 的 rect 坐标绘制。
///
/// 用**原生 SwiftUI 视图**（ZStack + ForEach + position）而非 Canvas：
/// Canvas 的渲染闭包不被 SwiftUI 追踪依赖，`pressed` 变化时不主动重绘，
/// 实测表现为"必须用鼠标按住预览图才高亮"。原生视图天然响应 @Published 状态。
struct KeyboardPreviewView: View {
    let bindings: [KeyBinding]
    let layer: KeyLayer
    let colors: [Int: Int]
    var selectedId: Int? = nil
    var pressed: Set<UInt8> = []
    var onSelect: ((KeyDef) -> Void)? = nil   // 须保持为最后一个参数（尾随闭包）

    @EnvironmentObject var model: AppModel

    // MARK: - 右上角布局覆盖（对照实物 1:1 重构）

    /// 4 颗快捷功能键 → 扁平横向小胶囊。
    /// 对齐 Num/// * 三列正上方，顶边与 F 行(top=29) 平齐；
    /// 总宽约为小键盘区(651→784)的 68%，4 颗等宽、间距 4px。
    static let capsuleRects: [Int: CGRect] = [
        71:  CGRect(x: 651.0, y: 29, width: 19.5, height: 17),   // BTPAIR
        89:  CGRect(x: 674.5, y: 29, width: 19.5, height: 17),   // LEDOFF
        107: CGRect(x: 698.0, y: 29, width: 19.5, height: 17),   // GAME
        109: CGRect(x: 721.5, y: 29, width: 19.5, height: 17)    // CALC
    ]

    /// 3 个音量键合并为 1 颗圆形旋钮：中心与胶囊中心线(y=37.5)对齐，
    /// 直径 = 标准键高(30) × 1.35 ≈ 40，横向位于 `-` 键正上方(center x=769)。
    static let knobRect = CGRect(x: 749, y: 17.5, width: 40, height: 40)
    static let knobIds: Set<Int> = [15, 16, 14]   // VOLDEC / MUTE / VOLINC

    private func screenRect(_ r: CGRect, scale: CGFloat, ox: CGFloat, oy: CGFloat) -> CGRect {
        CGRect(x: ox + r.origin.x * scale, y: oy + r.origin.y * scale,
               width: r.width * scale, height: r.height * scale)
    }

    // MARK: - body

    var body: some View {
        let layout = model.layout
        let dw = CGFloat(layout.canvasWidth)     // 设计宽 800
        let dh = CGFloat(layout.canvasHeight)    // 设计高 300

        GeometryReader { geo in
            // 关键：布局在**固定设计坐标系**（800×300）内完成，
            // 再整体 scaleEffect 缩放。此前在 GeometryReader 的动态坐标系里
            // 用 position 摆键，aspectRatio/frame 改变尺寸时
            // 视觉位置与 hit-test 坐标系不一致，导致普遍点不中。
            let scale = min(geo.size.width / dw, geo.size.height / dh)

            ZStack(alignment: .topLeading) {
                ForEach(layout.keys) { key in
                    keyBody(key, scale: 1, ox: 0, oy: 0)
                }
                knobBody(scale: 1, ox: 0, oy: 0)
            }
            .frame(width: dw, height: dh)
            .scaleEffect(scale)
            .frame(width: dw * scale, height: dh * scale)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(dw / dh, contentMode: .fit)
        .padding(6)
    }

    // MARK: - 渲染分支

    @ViewBuilder
    private func keyBody(_ key: KeyDef, scale: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        if Self.knobIds.contains(key.id) {
            EmptyView()                                  // 3 个音量键由旋钮统一渲染
        } else if let cr = Self.capsuleRects[key.id] {
            capsuleBody(key, rect: cr, scale: scale, ox: ox, oy: oy)
        } else if key.name == "LOCK" {
            indicatorBody(key, scale: scale, ox: ox, oy: oy)
        } else {
            normalBody(key, scale: scale, ox: ox, oy: oy)
        }
    }

    // MARK: - 普通键

    @ViewBuilder
    private func normalBody(_ key: KeyDef, scale: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        let r = screenRect(key.rect, scale: scale, ox: ox, oy: oy)
        let matched = Self.remapForMode(pressed, mode: model.keyboardMode)
        let isPressed = matched.contains(key.code)
        let isSelected = key.id == selectedId
        let isDiff = KeyboardMode.isDifferential(key.name)
        let label = Self.fit(model.keyboardMode.label(for: key.name), name: key.name)

        baseKeyShape(scale: scale, isPressed: isPressed, color: colors[key.id])
            .frame(width: r.width, height: r.height)          // 先定尺寸，overlay 才有正确容器
            .overlay {
                if let font = Self.fitFont(label: label, width: r.width, height: r.height) {
                    Text(label)
                        .font(font)
                        .foregroundColor(fgColor(isPressed: isPressed, color: colors[key.id]))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .overlay {
                borderOverlay(isSelected: isSelected, isPressed: isPressed,
                              isDiff: isDiff, scale: scale)
            }
            .position(x: r.midX, y: r.midY)                   // 最后定位
            .onTapGesture { onSelect?(key) }
    }

    // MARK: - 4 颗快捷功能键（横向小胶囊）

    @ViewBuilder
    private func capsuleBody(_ key: KeyDef, rect: CGRect, scale: CGFloat,
                             ox: CGFloat, oy: CGFloat) -> some View {
        let r = screenRect(rect, scale: scale, ox: ox, oy: oy)
        let matched = Self.remapForMode(pressed, mode: model.keyboardMode)
        let isPressed = matched.contains(key.code)
        let isSelected = key.id == selectedId
        let label = Self.fit(model.keyboardMode.label(for: key.name), name: key.name)

        Capsule(style: .continuous)
            .fill(isPressed ? Color.blue.opacity(0.85) : Color.secondary.opacity(0.25))
            .overlay {
                if let font = Self.fitFont(label: label, width: r.width, height: r.height) {
                    Text(label)
                        .font(font)
                        .foregroundColor(isPressed ? .white : fgColor(isPressed: false, color: nil))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .overlay {
                if isSelected {
                    Capsule(style: .continuous).stroke(Color.accentColor, lineWidth: 2)
                } else if isPressed {
                    Capsule(style: .continuous).stroke(Color.white, lineWidth: 1.5)
                } else {
                    Capsule(style: .continuous).stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                }
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .help("\(key.name) · 可自定义映射")
            .onTapGesture { onSelect?(key) }
    }

    // MARK: - LOCK → 嵌入式状态指示灯（不再是凸起键帽）

    @ViewBuilder
    private func indicatorBody(_ key: KeyDef, scale: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        let r = screenRect(key.rect, scale: scale, ox: ox, oy: oy)
        let matched = Self.remapForMode(pressed, mode: model.keyboardMode)
        let isOn = matched.contains(key.code)
        let isSelected = key.id == selectedId
        let slot = min(r.width, r.height) * 0.62

        ZStack {
            // 嵌入式凹槽
            RoundedRectangle(cornerRadius: slot * 0.28)
                .fill(Color.black.opacity(0.30))
                .frame(width: slot, height: slot)
                .overlay {
                    RoundedRectangle(cornerRadius: slot * 0.28)
                        .stroke(Color.black.opacity(0.45), lineWidth: 0.8)
                }
            // 指示灯点
            Circle()
                .fill(isOn ? Color.green : Color.white.opacity(0.35))
                .frame(width: slot * 0.46, height: slot * 0.46)
                .shadow(color: isOn ? .green.opacity(0.8) : .clear, radius: 3 * scale)
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
        .help("LOCK 状态灯 · 可自定义映射")
        .onTapGesture { onSelect?(key) }
    }

    // MARK: - 旋钮（3 个热区：左旋 / 中心按压 / 右旋）

    @ViewBuilder
    private func knobBody(scale: CGFloat, ox: CGFloat, oy: CGFloat) -> some View {
        let r = screenRect(Self.knobRect, scale: scale, ox: ox, oy: oy)
        let keys = model.layout.keys
        if let volDec = keys.first(where: { $0.id == 15 }),
           let mute = keys.first(where: { $0.id == 16 }),
           let volInc = keys.first(where: { $0.id == 14 }) {
            KnobView(rect: r, scale: scale,
                     volDec: volDec, mute: mute, volInc: volInc,
                     pressed: pressed, selectedId: selectedId,
                     mode: model.keyboardMode, onSelect: { onSelect?($0) })
        }
    }

    // MARK: - 共用键帽 / 描边

    /// 仅负责键帽填充。**不可**在此做 frame/position：
    /// overlay 必须作用在已确定尺寸、尚未 position 的视图上，
    /// 否则 position 返回的视图会填充整个容器，文字全部堆到中心。
    private func baseKeyShape(scale: CGFloat, isPressed: Bool, color: Int?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4 * scale)
        if let c = color {
            return AnyView(shape.fill(Color(red: Double((c >> 16) & 0xFF) / 255,
                                            green: Double((c >> 8) & 0xFF) / 255,
                                            blue: Double(c & 0xFF) / 255)))
        } else if isPressed {
            return AnyView(shape.fill(Color.blue.opacity(0.85)))
        } else {
            return AnyView(shape.fill(Color.secondary.opacity(0.25)))
        }
    }

    @ViewBuilder
    private func borderOverlay(isSelected: Bool, isPressed: Bool,
                               isDiff: Bool, scale: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4 * scale)
        if isSelected {
            shape.stroke(Color.accentColor, lineWidth: 2)
        } else if isPressed {
            shape.stroke(Color.white, lineWidth: 1.5)
        } else if isDiff {
            shape.stroke(Color.orange.opacity(0.7), lineWidth: 1)
        } else {
            shape.stroke(Color.black.opacity(0.25), lineWidth: 0.5)
        }
    }

    private func isBright(_ c: Int) -> Bool {
        let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
        return (r * 0.299 + g * 0.587 + b * 0.114) > 150
    }

    /// Mac 模式下固件会交换修饰键的 usage 输出（丝印标注的正是交换后的符号）：
    /// 物理 WIN 键(默认 code 0xE3) 在 Mac 模式发出 0xE2（丝印 option），
    /// 物理 ALT 键(默认 code 0xE2) 发出 0xE3（丝印 command）。
    /// 高亮要按「收到的 usage → 物理键」反查，故需此重映射；
    /// Windows 模式下 code 与固件一致，原样返回。
    static func remapForMode(_ usages: Set<UInt8>, mode: KeyboardMode) -> Set<UInt8> {
        guard mode == .mac else { return usages }
        var out = Set<UInt8>()
        for u in usages {
            switch u {
            case 0xE2: out.insert(0xE3)   // ← 物理 WIN 位（丝印 option）
            case 0xE3: out.insert(0xE2)   // ← 物理 ALT 位（丝印 command）
            case 0xE7: out.insert(0xE6)   // 右 Command → 物理 ALT_R 位
            default:   out.insert(u)
            }
        }
        return out
    }

    /// 模式标签优先（如 ⌘/⌥），否则回落到官方缩写。
    static func fit(_ modeLabel: String, name: String) -> String {
        if modeLabel != name { return modeLabel }   // 两模式不同 → 用模式标签
        return displayLabel(for: name)              // 否则走缩写/原名
    }

    private func fgColor(isPressed: Bool, color: Int?) -> Color {
        if isPressed { return .white }
        if let c = color { return isBright(c) ? .black : .white }
        return .primary
    }

    /// 窄键缩写：官方布局右上角 8 个键仅 10~23px 宽，原名必然溢出。
    static func displayLabel(for name: String) -> String {
        switch name {
        case "BTPAIR": return "BT"
        case "LEDOFF": return "LED"
        case "GAME":   return "GM"
        case "CALC":   return "C"
        case "VOLDEC": return "\u{2212}"   // 减号
        case "VOLINC": return "+"
        case "MUTE":   return "M"
        case "LOCK":   return "L"
        case "PRINT":  return "Prt"
        case "SCROOL", "SCROLL": return "Scr"
        case "pause", "PAUSE": return "PS"
        case "CapsLock": return "Caps"
        case "Insert": return "Ins"
        case "Delete": return "Del"
        case "Backspace": return "Bksp"
        case "Shift_L", "Shift_R": return "Shift"
        case "Ctrl_L", "Ctrl_R": return "Ctrl"
        case "Win_L", "Win_R": return "Win"
        case "Alt_L", "Alt_R": return "Alt"
        default: return name
        }
    }

    /// 按可用宽高收缩字号；放不下返回 nil（留白优于糊成一团）。
    static func fitFont(label: String, width: CGFloat, height: CGFloat) -> Font? {
        guard !label.isEmpty else { return nil }
        let maxW = width - 3
        let maxH = height - 3
        guard maxW > 4, maxH > 5 else { return nil }
        var size = min(10.0, Double(maxH) * 0.62, Double(maxW) * 0.62)
        while size >= 4.5 {
            let f = NSFont.systemFont(ofSize: CGFloat(size))
            let w = (label as NSString).size(withAttributes: [.font: f]).width
            if w <= maxW { return .system(size: CGFloat(size)) }
            size -= 0.5
        }
        return nil
    }
}


// MARK: - 按键自定义（改键）

struct RemapView: View {
    @EnvironmentObject var model: AppModel
    @State private var layer: KeyLayer = .top
    @State private var selected: KeyDef?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("按键自定义").font(.title2.bold())
                Spacer()
                Picker("层", selection: $layer) {
                    ForEach(KeyLayer.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Button("恢复整层默认") {
                    model.markUserAction()
                    model.resetLayer(layer: layer)
                }
                .disabled(model.busy)
                Button("应用整层到键盘") { model.markUserAction(); model.applyFullLayer(layer: layer) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }

            if let err = model.lastError {
                ErrorBanner(message: err) { model.lastError = nil }
            }
            if let n = model.notice {
                Text(n).font(.caption).foregroundStyle(.green)
            }
            if model.connection == .asleep {
                Text("⌨ 键盘休眠中：请按任意键唤醒后重试")
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 16) {
                KeyboardPreviewView(bindings: model.keyBindings, layer: layer,
                                    colors: [:], selectedId: selected?.id,
                                    pressed: model.pressedUsages) { key in
                    selected = key
                }
                .frame(maxWidth: .infinity)

                if let key = selected {
                    BindingEditor(key: key, layer: $layer)
                        .frame(width: 320)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("单击左侧按键编辑").foregroundStyle(.secondary)
                        Text("实测状态：帧回显 21/21 通过，但键位暂未物理生效（已试 Fn+Tab、AA55 终止符）。映射功能待后续排查。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .frame(width: 320, alignment: .topLeading)
                }
            }
        }
        .padding(24)
    }
}

/// 单键编辑器：选择目标 → 立即下发（真机验证的单键通路）
struct BindingEditor: View {
    let key: KeyDef
    @Binding var layer: KeyLayer
    @EnvironmentObject var model: AppModel

    @State private var kind = 0            // 0 默认 1 禁用 2 键/组合 3 媒体 4 宏
    @State private var mainKey = "A"
    @State private var mods: Set<Int> = []
    @State private var mediaIdx = 0
    @State private var macroSlot = 0

    private let mediaKeys: [(String, Int)] = [
        ("播放/暂停", 0xCD), ("停止", 0xB7), ("上一首", 0xB6), ("下一首", 0xB5),
        ("音量 +", 0xE9), ("音量 −", 0xEA), ("静音", 0xE2),
        ("计算器", 0x0192), ("邮箱", 0x018A), ("主页", 0x0223),
        ("搜索", 0x0221), ("刷新", 0x0227), ("前进", 0x0225), ("后退", 0x0224),
        ("收藏", 0x022A)
    ]

    private let modifierList: [(String, Int)] = [
        ("Ctrl", 0xE0), ("Shift", 0xE1), ("Alt", 0xE2), ("Win", 0xE3),
        ("RCtrl", 0xE4), ("RShift", 0xE5), ("RAlt", 0xE6), ("RWin", 0xE7)
    ]

    private var currentTarget: KeyTarget {
        switch kind {
        case 1: return .disabled
        case 2:
            let usage = Self.usage(for: mainKey)
            return .key(usage: usage, modifiers: mods.sorted())
        case 3: return .media(usage: mediaKeys[mediaIdx].1)
        case 4: return .macro(slot: macroSlot)
        default: return .default
        }
    }

    var body: some View {
        GroupBox("\(key.name) · \(layer.displayName)") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("功能类型", selection: $kind) {
                    Text("默认按键").tag(0)
                    Text("禁用按键").tag(1)
                    Text("按键 / 组合键").tag(2)
                    Text("多媒体").tag(3)
                    Text("宏").tag(4)
                }
                .pickerStyle(.radioGroup)

                switch kind {
                case 1:
                    Text("该键将无任何输出").font(.caption).foregroundStyle(.secondary)
                case 2:
                    HStack {
                        TextField("主键（如 A、F1、Enter）", text: $mainKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("修饰键（可多选）").font(.caption).foregroundStyle(.secondary)
                    let cols = [GridItem(.adaptive(minimum: 66))]
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(modifierList, id: \.1) { name, usage in
                            Toggle(name, isOn: Binding(
                                get: { mods.contains(usage) },
                                set: { if $0 { mods.insert(usage) } else { mods.remove(usage) } }))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                        }
                    }
                case 3:
                    Picker("多媒体键", selection: $mediaIdx) {
                        ForEach(Array(mediaKeys.enumerated()), id: \.offset) { i, k in
                            Text(k.0).tag(i)
                        }
                    }
                case 4:
                    Picker("宏槽位", selection: $macroSlot) {
                        ForEach(0..<10, id: \.self) { Text("宏 #\($0)").tag($0) }
                    }
                default:
                    Text("恢复为键盘默认输出").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("应用到键盘") {
                        var b = model.keyBindings.first { $0.keyId == key.id && $0.layer == layer }
                        b?.target = currentTarget
                        if let b { model.markUserAction(); model.applySingleKey(b) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)

                    Button("整层下发") { model.markUserAction(); model.applyFullLayer(layer: layer) }
                        .disabled(model.busy)
                }
                Text("帧格式已对齐上游（key_index 在 sub 字段），回显通过；物理生效待排查。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    static func usage(for name: String) -> Int {
        let n = name.trimmingCharacters(in: .whitespaces).uppercased()
        if n.count == 1, let ch = n.first, let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 {
            return Int(ascii - 65) + 4          // A..Z -> 0x04..0x1D
        }
        if n.count == 1, let d = n.first, d.isNumber {
            let idx = "1234567890".firstIndex(of: d)!
            return 0x1E + "1234567890".distance(from: "1234567890".startIndex, to: idx)
        }
        switch n {
        case "ENTER": return 0x28
        case "ESC", "ESCAPE": return 0x29
        case "BACKSPACE": return 0x2A
        case "TAB": return 0x2B
        case "SPACE": return 0x2C
        case "CAPSLOCK": return 0x39
        case "F1": return 0x3A; case "F2": return 0x3B; case "F3": return 0x3C
        case "F4": return 0x3D; case "F5": return 0x3E; case "F6": return 0x3F
        case "F7": return 0x40; case "F8": return 0x41; case "F9": return 0x42
        case "F10": return 0x43; case "F11": return 0x44; case "F12": return 0x45
        case "LEFT": return 0x50; case "RIGHT": return 0x4F
        case "DOWN": return 0x51; case "UP": return 0x52
        case "DELETE": return 0x4C; case "HOME": return 0x4A
        case "END": return 0x4D; case "PAGEUP": return 0x4B; case "PAGEDOWN": return 0x4E
        default: return 0x04
        }
    }
}

// MARK: - 宏管理器

struct MacrosView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Macro.ID?
    @State private var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("宏管理器").font(.title2.bold())
                Spacer()
                Button {
                    let m = Macro(name: "新宏 \(model.macros.count + 1)")
                    model.macros.append(m)
                    selected = m.id
                } label: { Label("新建", systemImage: "plus") }

                Button {
                    recording.toggle()
                } label: {
                    Label(recording ? "停止录制" : "开始录制",
                          systemImage: recording ? "stop.circle" : "record.circle")
                }
                .foregroundStyle(recording ? .red : .primary)
            }

            if let err = model.lastError {
                ErrorBanner(message: err) { model.lastError = nil }
            }

            Text("宏事件编码（04 15 / 04 19）尚未在真机验证，目前宏仅在本地保存与编辑，可绑定到按键（类型「宏」）。")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            HStack(alignment: .top, spacing: 16) {
                List(selection: $selected) {
                    ForEach(model.macros) { m in
                        VStack(alignment: .leading) {
                            Text(m.name).fontWeight(.medium)
                            Text("\(m.actions.count) 个动作 · 循环 \(m.playTimes == 0 ? "∞" : "\(m.playTimes)")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(m.id)
                    }
                    .onDelete { model.macros.remove(atOffsets: $0) }
                }
                .frame(width: 260)

                GroupBox("动作列表") {
                    if let id = selected, let idx = model.macros.firstIndex(where: { $0.id == id }) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("名称", text: $model.macros[idx].name)
                                    .textFieldStyle(.roundedBorder)
                                Stepper("循环 \(model.macros[idx].playTimes)",
                                        value: $model.macros[idx].playTimes, in: 0...255)
                                    .frame(width: 160)
                            }
                            Divider()
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(model.macros[idx].actions.enumerated()), id: \.offset) { i, a in
                                        HStack {
                                            Text("\(i + 1).").frame(width: 28, alignment: .trailing)
                                            Text(describe(a))
                                            Spacer()
                                            Button {
                                                model.macros[idx].actions.remove(at: i)
                                            } label: { Image(systemName: "trash") }
                                                .buttonStyle(.borderless)
                                        }
                                        .font(.system(.body, design: .monospaced))
                                    }
                                }
                                .padding(4)
                            }
                            HStack {
                                Button("插入延时 100ms") {
                                    model.macros[idx].actions.append(MacroAction(kind: .delay, delayMs: 100))
                                }
                                Button("清空") { model.macros[idx].actions.removeAll() }
                                Spacer()
                            }
                        }
                        .padding(4)
                    } else {
                        Text("选择或新建一个宏").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
    }

    private func describe(_ a: MacroAction) -> String {
        switch a.kind {
        case .keyDown: return "按下 键码 0x\(String(a.code, radix: 16))"
        case .keyUp:   return "松开 键码 0x\(String(a.code, radix: 16))"
        case .mouseDown: return "鼠标按下 \(a.code)"
        case .mouseUp:   return "鼠标松开 \(a.code)"
        case .delay:     return "延时 \(a.delayMs) ms"
        }
    }
}

// MARK: - 旋钮扇形热区

/// 圆内扇形，用于旋钮的左旋/右旋热区。
struct KnobSector: Shape {
    let start: Angle
    let end: Angle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        p.move(to: c)
        p.addArc(center: c, radius: radius,
                 startAngle: start, endAngle: end, clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - 旋钮视图（1 颗实体旋钮承载 3 个逻辑键位）

/// 对照实物：圆形大旋钮 + LED 导光环 + 金属内芯。
/// 逻辑上仍是 3 个独立键（音量− / 静音 / 音量+），通过 3 个热区分别交互。
struct KnobView: View {
    let rect: CGRect          // 屏幕坐标
    let scale: CGFloat
    let volDec: KeyDef        // 左弧：音量−
    let mute: KeyDef          // 中心：静音 M
    let volInc: KeyDef        // 右弧：音量+
    let pressed: Set<UInt8>
    let selectedId: Int?
    let mode: KeyboardMode
    let onSelect: (KeyDef) -> Void

    private func isOn(_ k: KeyDef) -> Bool {
        KeyboardPreviewView.remapForMode(pressed, mode: mode).contains(k.code)
    }

    var body: some View {
        let d = rect.width
        let centerFill = isOn(mute) || selectedId == mute.id ? Color.blue.opacity(0.85)
                                                             : Color.secondary.opacity(0.25)
        let ringOn = isOn(volDec) || isOn(volInc) || isOn(mute) || selectedId != nil
        let ringColor: Color = (selectedId == volDec.id || selectedId == volInc.id || selectedId == mute.id)
            ? Color.accentColor : (ringOn ? Color.blue.opacity(0.75) : Color.white.opacity(0.55))

        ZStack {
            // LED 导光环
            Circle()
                .stroke(ringColor, lineWidth: max(2, 3 * scale))
                .shadow(color: ringColor.opacity(ringOn ? 0.75 : 0.25), radius: 4 * scale)

            // 金属/磨砂旋钮内芯
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.93), Color(white: 0.78), Color(white: 0.66)],
                    startPoint: .top, endPoint: .bottom))
                .padding(d * 0.13)
                .overlay {
                    Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.8)
                        .padding(d * 0.13)
                }

            // 左弧热区（音量 −）
            KnobSector(start: .degrees(90), end: .degrees(270))
                .fill(isOn(volDec) ? Color.blue.opacity(0.55) : Color.clear)
                .contentShape(KnobSector(start: .degrees(90), end: .degrees(270)))
                .help("音量 −（旋钮左旋）· \(mode.label(for: volDec.name))")
                .onTapGesture { onSelect(volDec) }

            // 右弧热区（音量 +）
            KnobSector(start: .degrees(270), end: .degrees(450))
                .fill(isOn(volInc) ? Color.blue.opacity(0.55) : Color.clear)
                .contentShape(KnobSector(start: .degrees(270), end: .degrees(450)))
                .help("音量 +（旋钮右旋）· \(mode.label(for: volInc.name))")
                .onTapGesture { onSelect(volInc) }

            // 中心按压（静音 M）
            Circle()
                .fill(centerFill)
                .frame(width: d * 0.40, height: d * 0.40)
                .overlay {
                    Circle().stroke(Color.white.opacity(0.7), lineWidth: 1)
                }
                .overlay {
                    if let f = KeyboardPreviewView.fitFont(label: "M", width: d * 0.4, height: d * 0.4) {
                        Text("M").font(f).foregroundColor(isOn(mute) ? .white : .primary)
                    }
                }
                .contentShape(Circle())
                .help("静音 M（中心按压）")
                .onTapGesture { onSelect(mute) }
        }
        .frame(width: d, height: d)
        .position(x: rect.midX, y: rect.midY)
    }
}
