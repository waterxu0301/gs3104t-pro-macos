# GS3104T-PRO macOS 键盘助手

> 面向 **GANSS GS3104T-PRO** 机械键盘的 macOS 即开即用驱动 APP —— 通过逆向官方
> Windows 驱动的 HID 通信协议，在 macOS 上原生实现灯光控制、按键自定义、电量读取等完整功能。

**非官方项目**，与 GANSS 无关联。协议逆向仅用于个人学习与研究。

---

## 功能

| 功能 | 通路 | 状态 |
|---|---|---|
| 连接状态 / 电量 / 设备信息 | `02` `20` | ✅ 真机验证 |
| 灯光模式 · 颜色 · 亮度 · 速度 · 方向 | `05` 单包 | ✅ 背光实测生效 |
| 按键自定义（主层 / Fn 层） | `03`/`0D` 单键、`10`/`12` 整层 | ⚠️ 帧回显通过，物理生效待解 |
| 实时按键预览（含双系统键位） | 键盘 boot 接口原始输入 | ✅ 无需额外逻辑 |
| 预览模式开关 | 仅视觉高亮，不下发指令 | ✅ |
| Windows / macOS 双系统键位映射 | 按实物丝印映射 | ✅ |
| 系统配置（响应时间 / 休眠 / 禁用键） | 64B 会话 | ⚠️ 写通路未真机验证 |
| 宏管理器 | — | ⚠️ 编辑可用，事件编码未解 |

**不支持**：侧灯、TFT 屏（本机型硬件无此配置）、蓝牙模式设置。

**限制**：键位映射生效需按 `Fn+Tab` 开启驱动自定义按键（官方固件行为）；
键盘模式由固件切换：`Fn+A` → Windows，`Fn+S` → macOS。

---

## 构建

```bash
cd APP
./make_app.sh                    # 构建 + 打包 + 签名
open "dist/GS3104T-PRO 键盘助手.app"
```

要求：macOS 13+、Xcode（需要完整 SDK，CommandLineTools 不足）。

### 真机自检（不开窗口，走 GUI 同一套代码路径）

```bash
GANSS_CLI=1 "dist/GS3104T-PRO 键盘助手.app/Contents/MacOS/GANSSKeyboard"
# 期望：RESULT: ALL PASS
```

---

## 首次运行：输入监控权限

**实时按键预览需要「输入监控」权限**（macOS 强制要求，无法绕过）：

1. 打开 App，首页显示橙色引导横幅 → 点 **「打开系统设置」**
2. 系统设置 → 隐私与安全性 → **输入监控** → 添加本 App 并**开启**
3. **点红灯退出后重新打开**（TCC 权限变更对运行中的进程不生效）

> 权限不足时 KeyMonitor 返回 `kIOReturnNotPrivileged`（`0xe00002e2`）；
> 灯控与电量**仍可用**（vendor 通道不需该权限），仅实时按键预览失效。
> 从终端启动的实例会继承终端权限，开发时无需单独授权。

**退出行为**：点红灯（关闭窗口）即彻底退出进程，不留后台、不留 Dock 残留。

---

## 协议摘要

设备：`05AC:024F`，2.4G 模式配置接口 `UsagePage FF60 / Usage 61`，**MI_03（32 字节）为唯一命令通道**；MI_04（64B）仅回固定状态包 `0f 01 01 11`，应忽略。

```
帧（32B）: [0]=cmd [1]=len [2]=sub [3..]=payload [31]=checksum(sum(b[0..30]) & 0xFF)
应答:     头 3 字节回显 + 数据 + 同规则校验和
```

已验证命令：`02` 设备信息、`20` 电量、`05` 灯光、`03`/`0D` 单键、`10`/`12` 整层。

**休眠行为**：2.4G 空闲休眠时 MI_03 零应答，按任意键唤醒（APP 会自动检测并恢复）。

完整协议见 [`MacAPP/docs/PROTOCOL.md`](MacAPP/docs/PROTOCOL.md)，
真机验证记录见 [`MacAPP/docs/VERIFIED.md`](MacAPP/docs/VERIFIED.md)。

---

## 项目结构

```
MacAPP/
├── APP/
│   ├── Sources/GANSSKeyboard/
│   │   ├── HID/KeyboardTransport.swift   IOHIDManager 收发（MI_03 32B）
│   │   ├── HID/KeyMonitor.swift          按键实时监听（boot 键盘接口）
│   │   ├── HID/HeadlessTest.swift        真机自检 CLI
│   │   ├── Protocol/GanssProtocol.swift  帧构造/校验和/命令
│   │   ├── Model/                        布局解析、状态、配置档
│   │   └── Views/                        SwiftUI 界面
│   ├── Resources/                        键盘布局 XML、应用图标
│   ├── make_app.sh                       构建打包脚本
│   └── icon_gen.swift                    图标生成（CoreGraphics 自绘）
└── docs/                                 逆向分析与协议文档
```

---

## 开发踩坑记录

UI 实现的 10 条经验（Canvas 依赖不追踪、Auto Layout 崩溃、overlay/position 顺序、
hit-test 坐标系、List/NavigationSplitView 键盘与点击干预等）见
[`MacAPP/README.md`](MacAPP/README.md) 的「UI 实现要点」一节。

---

## 免责声明

- 本项目通过逆向工程分析官方驱动的 HID 通信协议，**仅供个人学习与研究使用**
- 不包含任何官方驱动的二进制文件、固件或受版权保护的资源
- 键盘布局 XML 仅包含键位坐标等事实性数据
- 使用本软件修改键盘配置的风险由使用者自行承担

## License

[MIT](LICENSE)
