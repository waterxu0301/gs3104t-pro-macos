# GS3104T-PRO 键盘助手（macOS）

即开即用的 GANSS GS3104T-PRO 键盘驱动 APP。协议层**已真机端到端验证**
（2.4G 通道：设备信息 / 电量 / 灯光 / 改键全部通过，见 `docs/VERIFIED.md`）。

## 使用

```bash
cd APP
./make_app.sh                                   # 构建 + 打包 + 签名
open "dist/GS3104T-PRO 键盘助手.app"
```

或解压 `dist/GS3104T-PRO键盘助手.zip` 后双击运行。

- 首次提示「无法验证开发者」→ 右键 App → 打开
- 若显示未连接：系统设置 → 隐私与安全性 → 输入监控 → 勾选本 App
- **键盘休眠时**：在键盘上按任意键，App 会自动检测并恢复（无需重启）

### 真机自检（不开窗口，走 GUI 同一套代码路径）

```bash
GANSS_CLI=1 "dist/GS3104T-PRO 键盘助手.app/Contents/MacOS/GANSSKeyboard"
# 期望：RESULT: ALL PASS
```

自检覆盖 GUI 实际执行的链路：连接 → 探测/唤醒 → 读设备信息与电量 → 写灯光 → 单键写入。

## 功能

| 功能 | 通路 | 状态 |
|---|---|---|
| 连接状态 / 电量 / 设备信息 | `02` `20` | ✅ 真机验证 |
| 首页预览图按键实时高亮 | 键盘 boot 接口原始输入 | ✅ 实测（无需额外授权） |
| 预览模式开关 | 仅视觉高亮，不下发任何指令 | ✅ 可开关 |
| 双系统键盘模式（Win/macOS） | 键名 + 高亮按丝印映射 | ✅ 与实物丝印一致 |
| 应用图标 | CoreGraphics 自绘 → icns | ✅ Dock/访达正常显示 |
| 灯光模式·颜色·亮度·速度·方向 | `05` 单包 | ✅ **背光实测生效** |
| 按键自定义（主层/Fn 层） | `03`/`0D` 单键、`10`/`12` 整层 21 块 | ⚠️ 帧回显 21/21 通过，**物理未生效**（见 VERIFIED.md） |
| 配置档（本地保存/批量下发） | 组合下发 | ✅ |
| 系统配置（响应时间/休眠/禁用键） | 64B 会话 `04 18…` | ⚠️ 写通路未真机验证 |
| 宏管理器 | — | ⚠️ 编辑可用，事件编码未解 |
| 自定义每键 RGB / 音乐律动 | — | ⚠️ 未验证，已禁用下发 |
| 侧灯 / TFT 屏 | — | ❌ 本机型不支持 |

限制与官方一致：蓝牙模式不支持设置；键位映射生效需按 **Fn+Tab** 开启。

## 架构

```
APP/Sources/GANSSKeyboard/
├── HID/KeyboardTransport.swift   IOHIDManager 收发（MI_03 32B / MI_04 64B）
├── HID/KeyMonitor.swift          按键实时监听（boot 键盘接口，供预览图高亮）
├── HID/HeadlessTest.swift        真机自检 CLI（GANSS_CLI=1）
├── Protocol/GanssProtocol.swift  帧构造/校验和/命令（实测命令表）
├── Model/                        布局 XML 解析、状态、配置档
└── Views/                        SwiftUI 界面 + 诊断日志
```

## 协议要点（详见 docs/VERIFIED.md）

- **通道**：`UsagePage FF60 / Usage 61`，**MI_03（32B）是唯一命令通道**；
  MI_04（64B）只回固定状态包 `0f 01 01 11`，忽略它
- **帧**：`[cmd][len][sub][payload…][checksum]`，`checksum = sum(b[0..30]) & 0xFF`
- **应答**：头 3 字节回显 + 数据 + 同规则校验和
- **休眠**：2.4G 空闲休眠时 MI_03 零应答 → 按任意键唤醒

## 图标

`icon_gen.swift` 用 CoreGraphics 自绘 1024×1024（深空蓝渐变 + 键帽阵列 + 橙色灯控高亮），
再由 `sips` + `iconutil` 生成 `Resources/AppIcon.icns`，`make_app.sh` 自动打入 bundle。

```bash
swift icon_gen.swift Resources/icons     # 重新生成图标
./make_app.sh                            # 打包（含 icns）
```

## UI 实现要点（踩过的坑）

1. **预览图必须用原生 SwiftUI 视图**（ZStack + ForEach + position），不能用 `Canvas`：
   Canvas 的渲染闭包依赖不被 SwiftUI 追踪，`pressed` 变化时不重绘 —— 实测表现为
   「必须用鼠标按住预览图才高亮」。
2. **不要在高频变化的文本上用 `textSelection`**，也不要用 `Spacer` 承载内容宽度变化：
   两者会反复触发约束重算，与 `hitTest` 并发时曾导致 **Auto Layout NSException 崩溃**
   （`_postWindowNeedsUpdateConstraints` → SIGABRT）。
3. **固定高度占位**：键盘图下方的控制条锁定 32pt，内容变化只改文字不改结构，
   避免键盘图被推挤上下浮动。
4. **窄键绘制**：官方布局右上角 8 个键仅 10~23px 宽，用缩写 + 字号自适应 + 放不下留白。
5. **侧边栏不要用 `List`**：List 自带 macOS 键盘导航/type-ahead，会把用户按键当作
   列表选择，导致预览模式下按方向键/字母键就跳到其他 tab。改用自绘
   `ScrollView + Button` 行，不参与键盘焦点系统。
6. **预览模式开关**：仅视觉高亮，不下发任何指令；关闭时不高亮。
7. **双系统模式映射**：键盘用 **Fn+A → Windows、Fn+S → macOS** 切换（固件实现，APP 无法远程改写）。
   Mac 模式下**固件交换修饰键 usage**（丝印 WIN 键印 `option`、ALT 键印 `command` 即是证明），
   故高亮必须做 `0xE2↔0xE3` 反向重映射，否则按 ⌘ 会亮到 ⌥ 的位置。键名按丝印：
   左下 `⌃ ⌥ ⌘`、右下 `⌘ Fn ⌥ ⌃`。
8. **`overlay` 必须作用在 `position` 之前**：`position` 返回的视图会**填充整个父容器**，
   若在其后做 `overlay`，文字会被画到容器中心堆叠（表现为"字都不见了"）。
   正确顺序：`fill → frame → overlay(文字) → position → onTapGesture`。
9. **预览图用固定设计坐标系 + scaleEffect**：在 `GeometryReader` 动态坐标系里用 `position` 摆键，
   当 `aspectRatio`/`frame(maxWidth:)` 改变尺寸时，视觉位置与 hit-test 坐标系不一致 → 普遍点不中。
   改为在 800×300 设计空间布局、再 `scaleEffect` 整体缩放，布局与命中同坐标系。
10. **侧边栏不要用 `NavigationSplitView` 承载自绘按钮**：其 sidebar 列会干预子视图点击分发，
    导致整排按钮点不动。改用 `HSplitView`（AppKit NSSplitView 包装）+ `.contentShape(Rectangle())`。

## 首次运行：输入监控权限

**实时按键预览需要「输入监控」权限**（macOS 强制要求，无法绕过）：

1. 打开 App，首页会显示橙色引导横幅 → 点 **「打开系统设置」**
2. 系统设置 → 隐私与安全性 → **输入监控** → 添加 `GS3104T-PRO 键盘助手.app` 并**开启**
3. **点红灯退出 App 后重新打开**（TCC 权限变更对运行中的进程不生效，必须重启）

> 权限不足时 KeyMonitor 返回 `kIOReturnNotPrivileged`（`0xe00002e2`），
> 灯控/电量等**仍可用**（vendor 通道不需要该权限），仅实时按键预览失效。

**签名说明**：本 App 为 ad-hoc 签名，**重新构建会改变 CDHash 导致授权失效**，
需重新授权。最终交付版签名已固定（二进制指纹 `6ab13c6d…`），授权一次即永久有效。
开发时从终端启动的实例会继承终端权限，无需单独授权。

## 退出行为

**点红灯（关闭窗口）即彻底退出进程**——不留后台、不留 Dock/状态栏残留，
符合「即开即用」定位。实现为 `applicationShouldTerminateAfterLastWindowClosed`，
退出前会清理 HID 资源（`KeyMonitor`/`Transport`）。

已实测：点击红灯后进程立即退出，无残留进程。

## 文档

- `docs/VERIFIED.md` — 真机验证记录（命令表、帧格式、休眠行为、改键实测）
- `docs/PROTOCOL.md` — Windows 驱动逆向的完整协议（3 通道、全部命令字）
- `docs/FEATURES.md` — 官方功能全集与本机型支持矩阵
- `docs/RE_NOTES.md` — DeviceDriver.exe 逆向笔记
- 上层 `../analysis/`、`../ref-yunjianj/` — 前期探索与上游逆向项目
