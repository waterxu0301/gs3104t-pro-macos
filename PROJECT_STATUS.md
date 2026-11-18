# GANSS 本地驱动项目现状汇总（供外部模型评审）

> 整理日期：2025-11-18 · 整理人：MiMo 会话（架构设计与实施者）
> 目的：向更强的模型征求「插件化重构 + FLX3 鼠标接入」方案的改进意见。
> 文档分四部分：项目背景 / 当前资产 / 已验证协议事实 / 待评审的架构提案。

---

## 一、项目背景与目标

### 1.1 起因

用户持有 GANSS GS3104T PRO 键盘（**序列号 DSM24 开头批次**）。官方网页驱动
`https://ganss.driveall.cn/#/` 基于 WebHID，只放行序列号 **DSMW** 开头的批次，
DSM24 批次在 HID 连接授权弹窗后报「不支持该设备或设备休眠了！！」。

**根因（已实测确认）**：该批次键盘将 USB VID/PID 混叠为
**`05AC:024F`（Apple Inc. 的 VID）**，产品名 `GS3104T-PRO 2.4G`。官方网页驱动
按 VID/PID 白名单过滤，DSM24 设备直接不匹配。社区推测混叠 Apple VID 是为了让
macOS 无驱直用。

### 1.2 现阶段目标（用户最新指令）

1. 将现有单机型驱动重构为**插件化、跨平台开源键鼠 Web 驱动框架**
2. 逆向接入 **GANSS FLX3 鼠标**（三模，官方网页驱动 `driver.yuandaxin-tech.com`，方案商远大芯科技）作为第二个插件
3. 补全键盘驱动能力：可视化全键配列 UI、组合键/媒体键/禁用键映射、**宏录制与下发**、配置回读
4. 插件生命周期管理（前端启停/导入/删除）+ 跨平台打包（macOS .app / Windows exe）

---

## 二、当前项目资产盘点

工作目录：`/Users/xujingrui/Documents/Dev/release/GANSS_Drive/`（**尚未 git 初始化**）

```
GANSS_Drive/
├── GS3104T-PRO驱动 固件 20250722.zip      # 官方素材（GBK 文件名 zip）
├── GS3104T-PRO驱动+固件 20241015/         # 官方素材（已解包）
│   ├── 驱动程序-GS3104T-PRO Driver-1.0.0.3.exe   # Windows 驱动，Inno Setup + PE 资源，已逆向
│   ├── DSM318_..._V1.20_20250722_0x2765.exe      # 固件升级器，内嵌 zip → SN32F290.hex (V1.20)
│   └── extracted/                          # 已用 7zz 解出的 PE 资源/固件/UISettings.ini
├── ref-yunjianj/                          # [开源参考1] yunjianj/GANSS_GS3104T_Pro (MIT)
├── ref-cubewhy/                           # [开源参考2] cubewhy/open-ganss-gs-3104t-pro (仅RGB, 123行)
└── ganss-mac/                             # ★ 本次交付的可运行成果（979 行代码）
```

### 2.1 `ganss-mac/`（当前可运行版本，端到端验证通过）

| 文件 | 行数 | 职责 | 来源 |
|---|---|---|---|
| `ganss/protocol.py` | 211 | 纯报文编码：灯光计划 / 键位整层 / 单键短报文 / 校验 | **复用** yunjianj（上游已实机验证） |
| `ganss/runner.py` | 28 | 报文计划逐步执行器，失败即停 | 复用 |
| `ganss/light_modes.py` | 24 | 19 种官方灯效编号+中文名 | 复用 |
| `ganss/profiles.py` | 52 | 本地 profiles.json 原子持久化 | 复用 |
| `ganss/macos.py` | 173 | **macOS 传输层**：ctypes 直调 hidapi C API（FF60 vendor 通道，feature 65B / short 33B） | 新写 |
| `ganss/macos_scan.py` | 108 | 设备枚举：VID/PID+产品名+FF60 usage page 匹配，按物理设备分组 | 新写 |
| `ganss/api.py` | 110 | JSON API dispatch（devices.scan / keys.list / lighting.set / keymap.set / keymap.apply） | 改写 |
| `ganss/server.py` | 69 | 本地 HTTP，127.0.0.1:8340，静态前端 + /api | 新写 |
| `web/index.html` | 199 | 单文件前端：设备列表/灯效模式网格/颜色亮度速度/单键映射输入框 | 新写（简陋） |
| `ganss/data/keymap.json` | — | 112 键位表（含 name/code/key_index/**rect 坐标**——可直接渲染键盘图） | 复用上游证据 |

运行环境：uv + Python 3.12 venv，依赖仅 `hidapi`（pip 包，内嵌 hidapi C 源码，macOS IOKit 后端）。
启动：`start.sh` → `python -m ganss`。

### 2.2 `ref-yunjianj/`（上游逆向项目，MIT，已克隆到本地）

本项目**协议可信度的根基**。要点：
- 基于官方 Windows 驱动 1.0.0.3 的完整静态反汇编（报告 `analysis/逆向报告.md`，约 500 行）
- 实机验证记录 `analysis/hardware-tests/results.md`：灯光、单键 A→B、整层映射、恢复默认，均在 2.4G 通道实机验证（2026-11-08，用户确认）
- 官方证据文件：完整 XML 键位表、灯效表、`database-schema.sql`（14 张表，含宏模型）、`protocol-disasm.txt`
- 自带 GUI/API/固件升级（Linux 端）

---

## 三、协议事实清单（按证据强度分级）

### A 级：已实机验证，可直接使用

| 协议 | 报文要点 |
|---|---|
| 有线 Feature 通道 | 65B API 缓冲区（report ID 0 + 64B 业务数据）；确认响应检查 `response[3]==1` |
| 无线短报文通道 | 33B：首字节 0，`[1:4]` 命令头，`[32]` 为前 32 字节低 8 位累加校验；写后等回显 `data[1:4]` |
| 灯光写入 | 无线：`05 10 00 + mode + rgb + colorful/brightness/speed/direction + AA55`；有线走 `04 18→04 13→参数块→04 02→04 F0` |
| 键位整层 | 576B 表 = 每键 4B 记录 `[type=2, modifier_mask, usage, 0]`，末尾 AA55；有线 9×64B，无线 21×28B；层选择 `04 11`(普通)/`04 27`(Fn)，无线 `10/12` |
| 单键映射（2.4G） | `03`(普通)/`0D`(Fn) + 长度 4 + key_index + 4B 记录 |
| 修饰键编码 | usage E0..E7 → bitmask 1..128，记录内最多一个普通键 + 多个修饰键 |

### B 级：协议线索存在，未逐项验证

| 项 | 线索 |
|---|---|
| 通用设置（回报率/休眠/响应时间） | 命令 `04 17`，P[2]=1、P[8]=1，后接数据块；字段布局未解 |
| 逐键灯光读取 | `04 F5` + 最多 9 块读取路径（0x44F240） |
| 固件升级 | `20 03` ISP 流程 + 5A5A 保护状态，已与官方抓包逐块核对，但 Linux/macOS 完整刷写未实机验证 |
| 键位记录其他类型字节 | type=1（`05 03` 前两字节）、type=3（宏引用：列表序号+2 参数）、type=13（3 参数低字节）——**这些是媒体键/宏/专用动作目标的编码空间** |

### C 级：仅知其存在，不可实现

| 项 | 现状 |
|---|---|
| **宏事件编码** | 传输前导 `04 15`（P[8]=块数，64B 对齐数据）+ 命令 `04 19`（未解码）。事件类型/延迟拆分/循环/容量上限均未恢复。上游明确声明"不提供可直接刷入的宏编码器" |
| 配置回读（键位层） | 无读取命令证据；官方驱动也是本地 SQLite 单向下发。逐键灯和 `04 20` 查询流程有读取路径 |
| Fn+Tab 开关状态 | 无法读取，只能提示用户 |

### 宏语义模型（官方数据库已还原，可作前端数据结构）

```sql
t_macro_data(macro_id, play_times, delay_type, delay_time, link_count, name)
t_macrorecord(macro_id, type, record_index, value, delay_time)   -- type: 按下/抬起事件
t_key_macro_data(profile, fn_layer, key_code, macro_type, macro_value...)
```

### FLX3 鼠标（目标新设备）已知信息

- 官方网页驱动：`https://driver.yuandaxin-tech.com/GANSS/FLX3_BK_2K/#/device`（WebHID）
- 三模（有线/2.4G/BT），UI 功能模块：6 键映射、DPI 多档+颜色、回报率/LOD/防抖/休眠、板载配置切换、配置导入导出、电量读取
- VID/PID、协议格式：**完全未知，待抓包**

---

## 四、已端到端实测的结果（macOS 真机）

| 测试 | 结果 |
|---|---|
| HID 枚举（ctypes 直调 hidapi） | 发现 `05AC:024F` 键盘全部 11 个接口，FF60 配置通道 interface 3（32B）与 4（64B）✅ |
| 设备扫描 API | 扫描/分组/命名去重正常 ✅ |
| 灯光写入（真实，非 dry-run） | 无线短报文 1 步写入成功，回显确认通过 ✅ |
| 单键映射通路 | `Q→Q` 等效默认映射写入成功（选 Q 因其无破坏性）✅ |
| dry-run 报文计划 | 灯光/键位计划生成正确，通道自动选择正常 ✅ |
| 前端 | 设备切换/灯效面板/映射输入框可用（交互简陋，无键盘可视化）|

**已知限制/坑**：
1. macOS hidapi `hid_get_error` 符号不存在（新版 hidapi 移除），错误处理已改为笼统报错
2. hidapi 枚举返回的 VID/PID 部分设备为 0000:0000（macOS 权限或复合设备解析问题），扫描匹配需同时依赖产品名和 usage page
3. 打字用的常规键盘接口可能被 macOS 独占，只能使用 FF60 vendor 接口
4. 键盘名含 `GS3104T-PRO 2.4G` 但**有线连接时**设备名不同（`HFD GS3104T PRO`），当前扫描匹配表已含两种名称
5. 未做 git 版本管理；未做打包分发

---

## 五、待评审的架构提案（用户已给出需求，尚未实施）

### 5.1 用户指定的重构方向

```
ganss-driver/
├── framework/
│   ├── transport/          # 跨平台抽象（mac IOKit / Windows / Linux hidraw）
│   ├── plugin_manager.py   # 发现/加载/启停/热插拔/删除
│   ├── safety.py           # 读-改-写-回读校验-自动回滚
│   ├── api.py / server.py
├── plugins/
│   ├── ganss_gs3104t_pro/  # manifest.json + driver.py + protocol.py + macro_codec.py
│   └── ganss_flx3/
├── web/
│   ├── components/         # keyboard-layout.js(用 rect 坐标) / mouse-view.js /
│   │                       # dpi-panel.js / macro-editor.js / plugin-manager.js
│   └── app.js              # 按 manifest ui_modules 动态装配
└── packaging/              # PyInstaller macOS .app / Windows exe / GitHub Actions
```

### 5.2 manifest.json 规范草案（要点）

- `match[]`: vid/pid/usage_page/product_regex/interface 多条件匹配（应对 VID 混叠）
- `capabilities[]`: 声明能力 → 前端据此装配组件
- `ui_modules[]`: 组件名 + props，新增型号免改前端
- `safety{}`: read_back_verify / full_block_write / experimental_write_mode

### 5.3 安全读写协议（用户指定，参考 libratbag 思路）

apply_config 强制流程：**读基线 → 只 patch 目标字段 → 整块下发 → 回读比对 → 失败重发一次 → 再失败自动回滚基线**。
⚠️ 评审要点：键盘键位层无回读命令（C 级事实），此流程对键盘只能降级为「本地 profiles.json 作真源 + 写入确认」。

### 5.4 用户需求中与协议现实冲突的点（需要权衡）

| 用户需求 | 协议现实 | 我的既定方案 |
|---|---|---|
| 宏录制+下发 | C 级，编码未恢复 | 编辑器/数据模型/插件接口先落地，编码器留白，抓包后填充 |
| 媒体键/禁用键作目标 | B 级（type 1/3/13 未枚举） | 同上，抓包补齐 |
| 配置回读同步前端 | 键位层无回读 | 本地配置文件作状态真源；灯光/逐键灯可回读 |
| FLX3 抓包 | — | 用 Chrome + CDP 在 navigator.hid 层挂钩子抓官方网页驱动的 sendReport |

### 5.5 遗留技术债

1. macos_scan.py 里 `_probe_caps()` 是空壳（原想探测 report 长度，hidapi macOS 不暴露描述符），通道选择靠 interface 编号硬编码 3/4 —— 跨平台重构时应改为能力探测
2. `api.py` 中 `_open_transport` 死代码（select_transport 返回值不匹配）
3. 传输层按 `'usb'/'wireless'` 分叉逻辑与 plan 的 channel 字段有冗余判断
4. 前端单文件 199 行，无组件化，与"动态装配"目标差距大
5. `profiles.py` 从上游复用但尚未接入前端（前端没做配置导入导出）
6. 错误提示对用户不友好（直接抛内部 OSError 文本）

---

## 六、请评审模型重点回答的问题

1. **插件化粒度**：manifest 驱动的动态 UI 装配（前端按 `ui_modules` 拼组件）vs. 每插件自带前端片段（更灵活但难维护），哪个更适合社区 PR 模式？有无更好的折中（如 JSON Schema 驱动的表单生成）？
2. **宏功能路径**：在协议未恢复的前提下，宏编辑器先行是否值得？还是等抓包确认后再做？抓包方案（CDP 挂 navigator.hid vs Wireshark USB vs macOS `hidtool`/iohidalog）哪种效率最高、最可靠？
3. **跨平台传输层**：ctypes 直调 hidapi C API（现状）vs. 换 `hid` Python 包（需修它的 dylib 查找）vs. hidapi C 库 brew 安装依赖——打包分发（PyInstaller）时哪种最省事最稳？
4. **安全读写**：对「无回读通道」的设备，read-modify-write-verify 如何降级设计才不误导用户？
5. **架构优先级**：在 FLX3 逆向尚未开始时，先重构框架还是先用现有单体架构把 FLX3 跑通再迁移？工作量与返工风险如何平衡？
6. **打包分发**：macOS .app 里内嵌 Python + hidapi + 静态前端的最佳实践（PyInstaller one-file vs .app bundle vs Nuitka）？签名/公证是否必须处理？
7. 其他你在评审中发现的、用户需求里遗漏或过度设计的点。

---

## 附：关键文件路径速查

| 内容 | 路径 |
|---|---|
| 当前可运行代码 | `ganss-mac/`（入口 `ganss/__main__.py`，服务 `ganss/server.py`） |
| 协议层（可信） | `ganss-mac/ganss/protocol.py` = `ref-yunjianj/ganss/protocol.py` |
| 键位表+布局坐标 | `ganss-mac/ganss/data/keymap.json`（112 键，含 rect_left/top/width/height） |
| 逆向报告（协议唯一权威来源） | `ref-yunjianj/analysis/逆向报告.md` |
| 实机验证记录 | `ref-yunjianj/analysis/hardware-tests/results.md` |
| 官方宏数据库结构 | `ref-yunjianj/analysis/evidence/database-schema.sql` |
| 全部 `04 xx` 命令候选 | `ref-yunjianj/analysis/evidence/command-immediates.json` |
| 官方固件 | `GS3104T-PRO驱动+固件 20241015/extracted/fwzip/Settings/FWFiles/SN32F290.hex` |
