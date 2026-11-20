import SwiftUI

// MARK: - 灯光模式

struct LightingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("灯光模式").font(.title2.bold())
                Spacer()
                Button("应用到键盘") { model.applyLighting() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }

            if let err = model.lastError {
                ErrorBanner(message: err) { model.lastError = nil }
            }

            Form {
                Section("模式") {
                    Picker("灯光模式", selection: $model.lighting.mode) {
                        ForEach(LightModes.realtime) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    Picker("主题灯效（组 A）", selection: $model.lighting.mode) {
                        ForEach(LightModes.themeA) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    Picker("经典灯效（组 B）", selection: $model.lighting.mode) {
                        ForEach(LightModes.themeB) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                }

                Section("参数") {
                    LabeledSlider(title: "亮度", value: $model.lighting.brightness,
                                  range: 0...model.layout.brightnessMax)
                    LabeledSlider(title: "速度", value: $model.lighting.speed,
                                  range: 0...model.layout.speedMax)
                    Picker("方向", selection: $model.lighting.direction) {
                        Text("上").tag(0)
                        Text("右").tag(1)
                        Text("下").tag(2)
                        Text("左").tag(3)
                    }
                    .pickerStyle(.segmented)

                    ColorPicker("颜色", selection: Binding(
                        get: { Color(rgb: model.lighting.color) },
                        set: { model.lighting.color = $0.rgbValue }
                    ), supportsOpacity: false)

                    Toggle("多彩（多色循环）", isOn: $model.lighting.colorful)
                }

                Section {
                    Text("当前：\(LightModes.name(id: model.lighting.mode)) · 亮度 \(model.lighting.brightness)/\(model.layout.brightnessMax) · 速度 \(model.lighting.speed)/\(model.layout.speedMax)")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding<Double>(
                get: { Double(value) },
                set: { value = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }
}

extension Color {
    init(rgb: Int) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
    var rgbValue: Int {
        let ns = NSColor(self)
        guard let c = ns.usingColorSpace(.sRGB) else { return 0xFFFFFF }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}

// MARK: - 自定义灯光（每键 RGB）

struct CustomLightView: View {
    @EnvironmentObject var model: AppModel
    @State private var brushColor: Color = .red
    @State private var selected: KeyDef?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("自定义灯光").font(.title2.bold())
                Spacer()
                ColorPicker("画笔颜色", selection: $brushColor, supportsOpacity: false)
                    .frame(width: 240)
                Button("填充全部") {
                    let v = brushColor.rgbValue
                    for k in model.layout.keys { model.perKeyColors[k.id] = v }
                }
                Button("清空") { model.perKeyColors.removeAll() }
                Button("上传到键盘") {
                    model.notice = "每键 RGB 上传（04 20）尚未真机验证，已跳过下发；画色暂存本地"
                }
            }

            if !model.layout.menuCustomLight {
                Text("提示：官方驱动中「自定义灯光」仅 USB 有线模式可用（menu_wireless 无 custom_light 属性）。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let err = model.lastError {
                ErrorBanner(message: err) { model.lastError = nil }
            }

            KeyboardPreviewView(bindings: [], layer: .top,
                                colors: model.perKeyColors,
                                selectedId: selected?.id) { key in
                selected = key
                model.perKeyColors[key.id] = brushColor.rgbValue
            }
            .frame(maxWidth: .infinity)

            HStack {
                if let key = selected {
                    Text("已选：\(key.name)")
                    if let c = model.perKeyColors[key.id] {
                        Text(String(format: "#%06X", c)).monospaced()
                    }
                }
                Spacer()
                Text("单击按键上色 · 已设置 \(model.perKeyColors.count) 键")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - 音乐律动

struct MusicView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode = 0
    @State private var amplitude = 3
    @State private var backgroundMode = 0
    @State private var backgroundBrightness = 3
    @State private var linkage = false

    private let modes = ["绿色/黄色/红色", "彩虹色", "彩虹色反向", "色谱", "频谱循环", "白色",
                         "红色", "橙色", "黄色", "绿色", "青色", "无", "蓝色", "紫色"]
    private let bgModes = ["无", "屏光联动"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("音乐律动").font(.title2.bold())
            Text("新音乐灯效（官方驱动 101-120 段）")
                .foregroundStyle(.secondary)

            if let err = model.lastError {
                ErrorBanner(message: err) { model.lastError = nil }
            }

            Form {
                Section("显示模式") {
                    Picker("模式", selection: $mode) {
                        ForEach(Array(modes.enumerated()), id: \.offset) { i, m in
                            Text(m).tag(i)
                        }
                    }
                    LabeledSlider(title: "振幅", value: $amplitude, range: 0...5)
                }
                Section("背景灯光") {
                    Picker("背景显示模式", selection: $backgroundMode) {
                        ForEach(Array(bgModes.enumerated()), id: \.offset) { i, m in
                            Text(m).tag(i)
                        }
                    }
                    LabeledSlider(title: "背景亮度", value: $backgroundBrightness, range: 0...5)
                    Toggle("屏光联动", isOn: $linkage)
                }
                Section {
                    Button("应用到键盘") {
                        model.notice = "音乐律动下发尚未真机验证，暂未启用"
                    }
                    .disabled(true)
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
    }
}
