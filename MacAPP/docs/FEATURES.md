# GANSS GS3104T-PRO 官方 Windows 驱动 功能盘点（复刻 macOS 版规格）

> 素材（均为只读分析，未修改任何源文件）：
> - `driver_app/app/language/2052.lan`（简体中文，UTF-16LE+BOM，`[SECTION]`/`id=文本`）、`1033.lan`（英文）、`1028.lan`（繁体）
> - `driver_app/app/layouts/rgb-keyboard.xml`（菜单开关、灯光默认值、键位布局）
> - `driver_app/app/config.xml`（设备/连接模式/语言/版本）
> - `driver_app/app/skins/theme1/icon/*.png`（功能页图标名）
> - `driver_app/app/DeviceDriver.exe`（PE32/MFC，imagebase 0x400000；SQLite 建表与增删改查语句、语言串加载函数）
>
> 语言文件编号段：1-11 主页 / 50-58 菜单 / 60-65 连接 / 70-85 灯光与按键通用 / 101-120 音乐律动 / 140-186 系统配置 / 201-342 按键功能与宏 / 360-386 宏录制与实时灯效 / 501-540 灯光模式 / 600-624 按键响应时间 / 660-670 侧灯 / 800-887 TFT 屏。

---

## 0. 本机型支持矩阵（以 `rgb-keyboard.xml` 为准）

```xml
<menu         macro="1" light_mode="1" sidelight="0" user_light="1" custom_light="1" music="1" screen="0" />
<menu_wireless macro="1" light_mode="1" sidelight="0" user_light="1"                   music="1" screen="0" />
<function     fn_layer="1" sleep_time="1" key_respondtime="1" />
<firmware     version="120" file="" url="" />
<cmd_delaytime value="35" />
<screen       gif_headlength="256" gif_maxframes="192" gif_count="1" width="128" height="128" />
<light        rgb_keyboard="1" default_mode="11" default_brightness="5" default_speed="3"
              brightness_max="5" speed_max="5" />
<Keyboard     bk_color="CD7A00" image="img_keyboard_layout.png" col_count="26" row_count="6"
              xpos="385" ypos="150" width="800" height="300">
```

| 功能 | 属性开关 | 有线(USB) `menu` | 无线(2.4G) `menu_wireless` | 本机型结论 |
|---|---|---|---|---|
| 宏管理器 | `macro` | ✅ 1 | ✅ 1 | 支持 |
| 灯光模式 | `light_mode` | ✅ 1 | ✅ 1 | 支持 |
| 用户灯光 | `user_light` | ✅ 1 | ✅ 1 | 支持 |
| 自定义灯光 | `custom_light` | ✅ 1 | ❌ 属性缺失 | **仅 USB 有线可用** |
| 音乐律动 | `music` | ✅ 1 | ✅ 1 | 支持 |
| 侧灯 | `sidelight` | ❌ 0 | ❌ 0 | **本机型不支持** |
| TFT 屏 | `screen` | ❌ 0 | ❌ 0 | **本机型不支持**（`<screen>` 尺寸参数仍保留在 XML 中，属通用模板残留） |
| Fn 层 / 休眠 / 按键响应时间 | `function` | ✅ 1 | ✅ 1 | 支持 |

其他静态结论：

- 连接模式只有两种：`mode value="0" desc="USB"`（`VID_05AC&PID_024F&MI_00`，产品名 `GS3104T PRO`）与 `mode value="2" desc="2.4G TYPE-A"`（`MI_03`，产品名 `GS3104T-PRO 2.4G`）。`config.xml` **未声明蓝牙模式**，但语言文件保留了蓝牙限制文案（62），说明驱动内核支持三模设备，本机型枚举里只有 USB/2.4G。
- 蓝牙限制文案（语言 62）：「蓝牙模式下，暂不支持键盘设置. 如需设置键盘，请使用USB连接或者2.4Ghz连接.」→ **蓝牙模式下所有键盘设置不可用**。
- 灯光默认：`default_mode=11`、`default_brightness=5`（= `brightness_max`，亮度 0-5 共 6 档）、`default_speed=3`（= `speed_max`，速度 0-5 共 6 档）。
- `cmd_delaytime=35`（驱动与设备通信的延时参数，ms）。
- 固件版本号 `firmware version=120`；TFT 模板 `gif_maxframes=192`、帧头 256 字节、128×128（但 `screen=0` 不支持）。
- 键位画布 26 列 × 6 行，112 个 `<key>` 条目（104 个标准键 + 8 个特殊键），`fnlayer_disable` 全为 0（即所有键都可进 Fn 层编辑）。

---

## 1. 完整功能树

```
主菜单 (50=主菜单 / Main Menu)
├─ 主页 (5)                                          [常驻，不看 menu 开关]
│   ├─ 已连接设备 (60) / 请连接设备 (61)
│   ├─ 正在查找设备… (63)
│   └─ 蓝牙模式限制提示 (62)                          ← 连接模式限制
├─ 我的专属配置 (51, 65)                              [多配置档，t_profile_data]
├─ 宏管理器 (52)                                      menu.macro=1 / menu_wireless.macro=1 ✅
├─ 灯光模式 (53)                                      menu.light_mode=1 / menu_wireless.light_mode=1 ✅
│   ├─ 背光模式列表（501-518 / 521-540 两套，见 §3）
│   ├─ 灯光颜色 (79) / 多彩 (80) / 调色板 (81)
│   ├─ 灯光亮度 (82) / 灯光速度 (83) / 灯光方向 (85)
│   ├─ 全选 (70) / 数字 (71)                          ← 自定义灯光逐键选择
│   └─ 自定义灯光 (78)                                menu.custom_light=1（仅 USB）✅
│       └─ 请选择自定义灯光方案 (385) / 导出灯光方案 (386)
├─ 用户灯光 (54)                                      menu.user_light=1 / menu_wireless.user_light=1 ✅
├─ 实时灯效 (55, 369)                                 9 种实时预览灯效（370-378，见 §3）
├─ 音乐律动 (56)                                      menu.music=1 / menu_wireless.music=1 ✅
│   ├─ 新音乐灯效 (101)
│   ├─ 显示模式/振幅 (102,103)  背景灯光显示模式/背景亮度 (104,105)
│   ├─ 颜色方案 (106-119)  屏光联动 (120)
├─ 侧灯 (660 侧灯模式)                                menu.sidelight=0 → ❌ 本机型不支持
├─ TFT屏 (58)                                         menu.screen=0 → ❌ 本机型不支持
│   └─ （能力清单见 §2.8，仅供以后带屏机型参考）
└─ 系统配置 (57)                                      function.* =1 ✅
    ├─ 按键响应时间 5 档 (140,149,600-624)
    ├─ 键盘休眠时间 (141-145)
    ├─ 禁用 Win 键 / Alt+F4 / Alt+Tab (160-162)
    ├─ 重置键盘 (152,165,166) / 恢复出厂 (153,167,168)
    ├─ 开机启动 (151) / 语言 (150) / 关闭主窗口行为 (170-172)
    └─ 驱动更新 (156,175,176) / 固件更新 (157,177,180-186)

通用交互（语言 20-37）：确定/取消/应用/是/否/导入/导出/添加/编辑/删除/复制/粘贴/重命名/新建/剪切/重置
主页按钮（语言 5-11）：主页 / 商店 / 配置 / 退出
```

> 说明：`rgb-keyboard.xml` 的 `menu` 属性是**功能总开关**，语言 50-58 是**菜单文案**。二者并非一一对应：
> `custom_light`（自定义灯光，语言 78）没有对应的菜单 id，它作为灯光页内的子功能出现；`实时灯效`（55）有菜单 id 但没有属性，跟随 `light_mode` 开关。

### 1.1 皮肤图标 → 功能页（`skins/theme1/icon/`）

| 图标 | 推断功能页 |
|---|---|
| `tab_home.png` | 主页 |
| `tab_customkey.png` | 自定义按键（改键/Fn 层） |
| `tab_light.png` | 灯光模式 |
| `tab_customlight.png` | 自定义灯光 |
| `tab_userlight.png` | 用户灯光 |
| `tab_macro.png` | 宏管理器 |
| `tab_music.png` | 音乐律动 |
| `tab_sidelight.png` | 侧灯（本机型隐藏） |
| `tab_tft.png` | TFT 屏（本机型隐藏） |
| `tab_config.png` | 系统配置 |
| `usb_mode.png` / `24g_mode.png` / `bt_mode.png` / `icon_bluetooth.png` | 连接模式指示 |
| `icon_battery_bkg.png` / `icon_batteryvalue.png` / `icon_charge.png` | 电量/充电（无线） |
| `icon_brightness_up.png` / `icon_brightness_down.png` / `icon_light_swicth.png` / `icon_light_on.png` / `icon_key_light.png` | 亮度与灯控 |
| `icon_input_delay.png` / `icon_input_up.png` / `icon_input_down.png` | 按键响应时间 |
| `icon_macro.png` / `btn_record_*.png` / `imgbtn_{add,del,edit,export,import}.png` | 宏录制与宏列表 |
| `icon_{multimedia,win,pc,cal,file,email,favorites,keyboard}.png` | 按键功能类型 |
| `icon_key_{top,bottom,left,right,command,enter,light}.png` | 键位编辑辅助 |
| `icon_vol_{up,down,mute}.png` / `icon_{playpause,next,pre,stop}.png` | 多媒体键 |
| `icon_web_{backward,foreward,refresh,search,stop}.png` | 网页快捷键 |
| `icon_tft.png` / `imgbtn_lcd_*.png` / `img_lcdedit_bkg.png` | TFT/GIF 编辑 |
| `icon_palette_bar1.png` / `img_circlepalette.png` / `img_direction_{top,bottom,left,right}.png` | 调色板与方向 |
| `icon_customlayout.png` / `img_key_edit*.png` | 自定义键位 |

---

## 2. 各功能：可调项 / 取值范围 / 默认值 / 连接限制

### 2.1 主页（5）

| 项 | 语言 id | 说明 |
|---|---|---|
| 已连接设备 | 60 | 显示当前连接的设备（USB / 2.4G） |
| 请连接设备 | 61 | 未连接时占位 |
| 查找设备提示 | 63 | 「正在查找设备…若是无线设备请按一下按键解除休眠状态」 |
| 蓝牙限制 | 62 | 蓝牙连接时禁用所有键盘设置 |

设备图：`device/home_keyboard_connected.png`、`home_keyboard_disconnected.png`（`config.xml` 的 `img_connected/img_disconnected`）。

### 2.2 我的专属配置（51/65）— 多配置档

- 数据表 `t_profile_data(profile PK, name, status, app, type)`：
  - `name`：配置档名（UI 提供 新建/重命名/删除/复制 → 语言 35/33/30/31）
  - `status`：0/1，**同一时刻只有一个激活档**（`UPDATE t_profile_data SET status=?` 无 WHERE = 清全部，再置当前档）
  - `app`：绑定的应用程序路径 → **按应用自动切换配置档**（t_profile_data 有 `app` 字段）
  - `type`：配置档类型（内置/自定义）
- 所有配置档数据均带 `profile` 外键：`t_config_data`、`t_key_macro_data`、`t_light_data`、`t_userlight_data`、`t_userlightrgb_data`、`t_customlight_data`、`t_musiclayer_data`、`t_ledlayer_data` 都按 `profile` 分区。
- 档位数量上限：静态资源未给出明确数值（`SELECT profile FROM t_profile_data WHERE status=?`、`SELECT * FROM t_profile_data` 无 LIMIT），**需运行时验证**。

### 2.3 宏管理器（52）

可调项（语言 300-363、242-247）：

| 项 | 语言 id | 取值/说明 |
|---|---|---|
| 输入记录列表 / 动作记录列表 | 300, 323 | 宏的动作序列视图，列：按键(335) / 动作(336) / 延时(毫秒)(337) |
| 新建宏 / 编辑录制的宏文件 / 重命名 / 删除 / 导出宏 | 331, 301, 33, 312, 341 | 宏列表 CRUD + 导出 |
| 开始录制 / 停止录制 | 321, 322 | 键盘+鼠标输入录制 |
| 键盘输入动作 / 鼠标输入动作 | 304, 305 | 录制来源 |
| 鼠标左/中/右键 | 307, 308, 309 | 可作为宏动作插入 |
| 在动作列表光标条上/下方插入 | 302, 303 | 手工插入动作 |
| 修改延时时间 / 向上移动 / 向下移动 | 325, 326, 327 | 动作编辑 |
| 记录输入间隔时间 / 不记录输入间隔时间 / 默认间隔 | 317, 318, 319 | 录制时是否保留真实延时；单位毫秒(320) |
| 重复次数 | 316 | 见播放方式 |
| **播放方式** | 242-247 | 播放一次 / 播放多次 / 再按键时停止 / **循环计数 1~255** / 松开停止 / 点按播放 |
| 保存 | 329 | 写入 `t_macro_data` + `t_macrorecord` |
| 提示 | 330, 340, 342, 360-363 | 重命名失败/未选中/未新建提示；**宏录制空间提示：不足(361)、即将不足(362)、已达上限(363)** |

- 宏数据模型：`t_macro_data(macro_id, play_times, delay_type, delay_time, link_count, name)` ↔ `t_macrorecord(macro_id, type, record_index, desc, value, delay_time)`（`type` 区分键盘/鼠标动作）。
- 按键 → 宏绑定：`t_key_macro_data(profile, fn_layer, key_code, layout_value, layout_desc, macro_type, macro_value, macro_value2, macro_value3, macro_desc)`，按 `(profile, fn_layer, key_code)` 唯一定位（有 DELETE/SELECT 语句），说明**宏可分别绑定到顶层与 Fn 层**。
- 宏总空间有上限（由固件决定，静态资源未给出字节数）。

### 2.4 灯光模式（53）

| 可调项 | 语言 id | 取值范围 | 默认值 |
|---|---|---|---|
| 模式 | §3 两套列表 | 见 §3 | `default_mode=11` |
| 灯光亮度 | 82 | 0 ~ `brightness_max`=5（共 6 档） | `default_brightness=5` |
| 灯光速度 | 83 | 0 ~ `speed_max`=5（共 6 档） | `default_speed=3` |
| 灯光方向 | 85 | 4 向（`img_direction_top/bottom/left/right.png`） | 未在 XML 给出 |
| 灯光颜色 / 调色板 / 多彩 | 79 / 81 / 80 | 单色 RGB、8 个默认调色板色、"多彩"开关 | 调色板默认色见 §5.3 `default_color1~8` |
| 全选 / 数字 | 70 / 71 | 逐键选择（自定义灯光用） | — |

- 落库：`t_light_data(light_id, profile, name, mode, brightness, speed, direction, colorful, colorindex, color_value, config_func, reserved, status)`，按 `(profile, mode)` 更新，`status` 标记当前生效模式（`SELECT mode FROM t_light_data WHERE profile=? AND status=?`）。
- 连接限制：`light_mode` 在 `menu` 与 `menu_wireless` 中均为 1 → **USB 与 2.4G 都可设置**；蓝牙不可。

### 2.5 自定义灯光（78，`custom_light`）

- **仅 USB 有线**（`menu_wireless` 无 `custom_light` 属性）。
- 数据：`t_customlight_data(customlight_id, profile, name, speed, brightness, status)` + `t_customrgb_data(customrgb_id, customlight_id, keycode, rgbvalue, light_mode, colortype, light_type)`
  - `rgbvalue`：该键颜色；`light_mode`：该键灯效模式；`colortype`：颜色类型；`light_type`：灯类型（RGB/单色）
- UI：方案列表（新建/删除/重命名/导出，语言 385「请选择自定义灯光方案」、386「导出灯光方案」）、逐键点选 + 调色板(81) + 亮度(82) + 速度(83)。
- 配置键：`customlight`、`customlight_run`（是否正在运行自定义灯效）。

### 2.6 用户灯光（54，`user_light`）

- 数据：`t_userlight_data(userlight_id, profile, name, speed, brightness, status)` + `t_userlightrgb_data(userlightrgb_id, profile, userlight_id, key_code, key_rgb)`
  - 每个方案 = 逐键 RGB 表（`key_code → key_rgb`），带方案级 `speed/brightness/status`。
- 与自定义灯光的区别：用户灯光是"整套按键配色方案"（纯 RGB 上色），自定义灯光额外带 `light_mode/colortype/light_type`（每键可指定灯效模式）。
- 连接限制：`menu` 与 `menu_wireless` 均为 1 → USB/2.4G 均可；蓝牙不可。

### 2.7 实时灯效（55 / 369）

- 9 个模式（370-378，见 §3），带亮度/速度等通用参数。
- 代码中被直接引用：`push 0x172..0x17a`（=370..378）后 `call 0x3f8a0`（语言串加载器），位于 VA `0x398be` 与 `0x4223a` 两处列表构建点；标题 369 在 `0x27934`、`0x42c68` 等。
- 无独立 menu 属性，跟随 `light_mode`。

### 2.8 音乐律动（56，`music`）

| 可调项 | 语言 id | 说明 |
|---|---|---|
| 新音乐灯效 | 101 | 新建律动方案 |
| 显示模式（EN: Rhythm） | 102 | 前景律动模式 → `t_musiclayer_data.foremode` |
| 振幅（EN: Amplitude） | 103 | → `fore_amplitude` |
| 背景灯光显示模式 | 104 | → `backmode` |
| 背景亮度 | 105 | → `backb_right` |
| 颜色预设 14 项 | 106-119 | 绿/黄/红、彩虹、彩虹反向、色谱、频谱循环、白、红、橙、黄、绿、青、无、蓝、紫 |
| 屏光联动（EN: Ambilight） | 120 | 依赖 TFT 屏，本机型 `screen=0` → 不可用 |
| 音频采集设备 | — | `t_musiclayer_data.deviceindex` |
| 方案选中 | — | `t_musiclayer_data.sel`（每 profile 一个选中项） |

- 表结构：`t_musiclayer_data(layer_id, profile, name, deviceindex, foremode, fore_amplitude, backmode, backb_right, sel)`，每 profile 有条数上限（`select count(*) FROM t_musiclayer_data WHERE profile=?`）。
- 连接限制：`music` 在 menu/menu_wireless 均为 1 → USB/2.4G 可用；蓝牙不可。

### 2.9 侧灯（`sidelight=0` → ❌ 本机型不支持）

- 语言 660「侧灯模式」+ 661-670 共 **10 个模式**（代码 VA `0x4116d`：`mov ecx,0x295(661)` … `lea eax,[ecx-0x295]; cmp eax,0xa; jl` 循环加载 661..670）。
- 复刻建议：数据结构保留（`t_light_data` 可复用），UI 按 `sidelight=0` 隐藏。

### 2.10 TFT 屏（`screen=0` → ❌ 本机型不支持）

语言 800-887 描述的完整能力（供以后带屏机型参考）：

- 方案：名称(800)、新建(803)、导入(804)、删除(805)、导入 GIF(834)、删除 LED(836)、保存并上传开机动画(848)
- 帧：**最大 192 帧**（2052.lan 802/832；1033.lan 写 256/255，属多语言文件不一致，以 XML `gif_maxframes=192` 为准）、新建一帧(814)、复制前一帧(815)、删除选中帧(818)、复制帧(842)、删除帧(844)
- 编辑：画笔(816)/橡皮擦(817)、画笔-细/中/粗(880-882)、清空编辑(884)、撤销修改(885)、原图(886)、比例 100%(883)、栅格(862)、字号(860)
- 文字：文字输入(810)、输入后按 Enter 确认(811)、添加文本(813)/添加文字(839)、颜色设置(812)
- 延时：当前帧延时(825)、所有帧延时(826)、时间校正(827)、延迟时间(837)、时间提示(807：30-500ms)
- 输出：图片预览(806)、LED 屏预览(801)、效果预览(809)、保存 GIF(819)、导出 GIF(820)、上传到键盘(821)
- 屏幕参数：128×128，`gif_headlength=256`，`gif_count=1`

### 2.11 系统配置（57）→ 详见 §5

---

## 3. 全部灯光模式名称与序号

### 3.1 实时灯效（369-378，代码直接引用 ✅）

| id | 简体 (2052) | English (1033) |
|---|---|---|
| 369 | 实时灯效（页标题） | Real-time Lighting |
| 370 | 静态恒亮 | Static On |
| 371 | 繁星点点 | Starlight |
| 372 | 漫天飞舞 | Fluttering |
| 373 | 动态呼吸 | Dynamic Breathing |
| 374 | 彩泉涌动 | Colorful Fountain |
| 375 | 多彩纵横 | Rainbow Wave |
| 376 | 随波逐流 | Following Currents |
| 377 | 峰回路转 | Peak Revolving |
| 378 | 关闭灯光 | Turn Off Lighting |

### 3.2 背光模式组 A（501-518，共 18 项）

| id | 简体 | English（1033 第二块） |
|---|---|---|
| 501 | 引力波动 | Gravitational fluctuation |
| 502 | 电子跃迁 | Electronic transition |
| 503 | 穿越虫洞 | Through wormhole |
| 504 | 空间泡沫 | Space foam |
| 505 | 重力喷泉 | Gravity fountain |
| 506 | 太阳风暴 | Solar storm |
| 507 | 离子推进 | Ion propulsion |
| 508 | 偏振光波 | Polarized lightwave |
| 509 | 时间沙漏 | Time hourglass |
| 510 | 光粒打击 | Light particle strike |
| 511 | 能量湮灭 | Energy annihilation |
| 512 | 超膜广播 | Ultra-membrane broadcasting |
| 513 | 时空扭曲 | Space-time warping |
| 514 | 电磁弹射 | Electromagnetic ejection |
| 515 | 粒子加速 | Particle acceleration |
| 516 | 恒星纪元 | Stellar era |
| 517 | 量子涨落 | Quantum fluctuation |
| 518 | 关闭背光 | Backlight Off |

> `1033.lan` 中另有一块 **500-519** 的同批模式旧译名（500=Stellar Epoch、501=Photon Strike … 519=Backlight Off），与上表 id 重叠——同文件内后写覆盖前写，且 `2052.lan` 只有 501-518 一块，因此**以 501-518 为准**，500-519 视为废弃译名。

### 3.3 背光模式组 B（521-540，共 20 项）

| id | 简体 | English |
|---|---|---|
| 521 | 静态恒亮 | Static |
| 522 | 单点亮 | SingleOn |
| 523 | 单熄灭 | SingleOff |
| 524 | 繁星点点 | Glittering |
| 525 | 漫天飞雪 | Falling |
| 526 | 百花争艳 | Colourful |
| 527 | 动态呼吸 | Breath |
| 528 | 光谱循环 | Spectrum |
| 529 | 彩泉涌动 | Outward |
| 530 | 多彩纵横 | Scrolling |
| 531 | 随波逐流 | Rolling |
| 532 | 峰回路转 | Rotating |
| 533 | 一触即发 | Explode |
| 534 | 一石二鸟 | Launch |
| 535 | 涟漪扩散 | Ripples |
| 536 | 川流不息 | Flowing |
| 537 | 重峦叠嶂 | Pulsating |
| 538 | 斜风细雨 | Tilt |
| 539 | 来回穿梭 | Shuttle |
| 540 | 关闭背光 | LED Off |

> **组 A / 组 B 归属（待运行时确认）**：静态扫描未能在 `DeviceDriver.exe` 中定位到 501/521 的立即数引用（只有 370-378 与 660-670 被 `push`/`mov reg,imm` 直接引用；501-517 仅作为**另一处下拉框的 item-data 枚举**出现在 VA `0x37205`、`0x405cf`，其文本来自语言 id 252/270-279 等快捷方式文案，与模式名无关）。因此两套都完整列出，复刻时建议：
> - 两套模式表都实现，按设备/模式索引选择；
> - 若 `default_mode=11` 是 0 基索引：组 A → 511「能量湮灭」，组 B → 532「峰回路转」，可用「驱动里默认显示哪个模式」一次验证归属；
> - 组 B 的命名风格与实时灯效(370-378)高度重合（静态恒亮/繁星点点/彩泉涌动/多彩纵横/随波逐流/峰回路转），**推测组 B 是本机型主背光模式表**，组 A 是另一机型/另一灯区的模式表。

### 3.4 侧灯模式（660-670，`sidelight=0` → 不支持；代码已验证循环 10 项）

| id | 简体 | English |
|---|---|---|
| 660 | 侧灯模式（标题） | Side Light Mode |
| 661 | 流光 | Flowing Light |
| 662 | 常亮红色 | Red |
| 663 | 常亮黄色 | Yellow |
| 664 | 常亮绿色 | Green |
| 665 | 常亮冰蓝 | Ice Blue |
| 666 | 常亮蓝色 | Blue |
| 667 | 常亮粉红 | Pink |
| 668 | 常亮白色 | White |
| 669 | 霓虹 | Neon |
| 670 | 熄灭 | Off |

---

## 4. 按键功能类型（201-298）与宏录制能力（300-363）

### 4.1 顶层类型（201-213、218）

| id | 简体 | English | 说明 |
|---|---|---|---|
| 201 | 默认按键 | Default Key | 恢复出厂键位 |
| 202 | 禁用按键 | Disable Key | 禁用该键 |
| 203 | 自定义功能 | Custom Function | 进入自定义功能选择 |
| 204 | 按键类型 | Key Type | 分类标题 |
| 205 | 按键功能 | Key Function | 分类标题 |
| 206 | 宏定义 | Macro Definition | 绑定宏（→ `t_key_macro_data.macro_type`） |
| 207 | 鼠标功能 | Mouse Function | |
| 208 | 多媒体 | Multimedia | |
| 209 | Windows快捷方式 | Windows Shortcut | |
| 210 | 打开程序 | Open Program | → `t_key_otherdata`（macro_desc/param/type） |
| 211 | 打开网站 | Open Website | |
| 212 | 发送文字 | Send Text | |
| 213 | 多键 | Multi-Key | 组合键序列 |
| 218 | 打开文件 | Open File | |

### 4.2 鼠标功能（220-228）

| id | 简体 | id | 简体 |
|---|---|---|---|
| 220 | 左键单击 | 225 | 向上滚动 |
| 222 | 中键单击 | 226 | 向下滚动 |
| 223 | 右键单击 | 227 | 鼠标按钮5 |
| 224 | 双击 | 228 | 鼠标按钮4 |

（221 编号空缺）

### 4.3 多媒体（230-236）

| id | 简体 | id | 简体 |
|---|---|---|---|
| 230 | 播放/暂停 | 234 | 音量 + |
| 231 | 停止 | 235 | 音量 - |
| 232 | 上一首 | 236 | 静音 |
| 233 | 下一首 | | |

其他：`237 该按键不能设置`、`238 单击鼠标左键更改键位设置，单击鼠标右键选择更多功能`（交互提示）、`241 请选择一种类型`。

### 4.4 宏播放方式（242-247）

| id | 简体 | English |
|---|---|---|
| 242 | 播放一次 | Play Once |
| 243 | 播放多次 | Play Multiple Times |
| 244 | 再按键时停止 | Stop when key is pressed again |
| 245 | 循环计数(1 ~ 255) | Loop Count (1 ~ 255) |
| 246 | 松开停止 | Release to stop |
| 247 | 点按播放 | Click to play |

### 4.5 Windows 快捷方式（251-259）

显示桌面(251)、我的电脑(252)、锁定计算机(253)、关闭窗口(254)、切换Windows(255)、注销(256)、睡眠(257)、关机(258)、重启(259)。

### 4.6 打开程序/网页预设（270-279）

计算器(270)、邮箱(271)、多媒体(272)、主页(273)、网页-刷新(274)、网页-停止(275)、网页-向后(276)、网页-向前(277)、网页-收藏(278)、网页-搜索(279)。

> 代码证据：VA `0x371ee` 起的列表构建 `push 0xfc(252) → push 0x10e(270) → 0x10f(271) → 0x110(272) → 0xe6..0xec(230..236) → 0x111..0x118(273..280)`，同时把 item-data 依次写为 500,501,…,517 —— 即**内部预设枚举 500+**，与语言 501-518 模式名编号只是巧合，勿混淆。

### 4.7 层与编辑模式（290-298）

| id | 简体 | English |
|---|---|---|
| 290 | 编辑单键 | Top Layer（顶层） |
| 291 | 编辑Fn组合键 | Fn Layer（Fn 层） |
| 292 | Fn开关功能 | Fn Switch Function |
| 293 | 使用单键 | Momentary（按住生效） |
| 294 | 使用组合键 | Toggle（切换生效） |
| 295 | 编辑单个按键的自定义快捷键方式 | Edit custom shortcut for single key |
| 296 | 编辑（Fn+单个按键）的自定义快捷键方式 | Edit custom shortcut for (Fn+single key) |
| 297 | 直接输出单键编辑结果 | Output the result of editing single key directly |
| 298 | 只按单键直接输出组合键编辑结果 | Output the result of editing combination key directly |

- 配置键 `fn_layer`（Fn 层开关，function.fn_layer=1）、`fn_switch`（Fn 开关功能）。
- `t_key_macro_data.fn_layer` 字段区分顶层/Fn 层；`rgb-keyboard.xml` 中 112 键的 `fnlayer_disable` 全为 0 → **所有键都可编辑 Fn 层**。
- 编号空缺：214-217、219、221、229、239-240、248-250、260-269、280-289（语言文件未使用）。

### 4.8 宏录制能力（300-363）

见 §2.3 表格。要点：

- 录制源：键盘输入(304) + 鼠标输入(305，左/中/右键 307-309)
- 延时策略：记录输入间隔(317) / 不记录(318) / 默认间隔(319)，单位毫秒(320)，可手工修改延时(325)
- 播放：一次/多次/再按停止/循环 1~255/松开停止/点按播放（242-247）
- 动作编辑：插入(310)、上移/下移(326/327)、删除(312)、重命名(33)、保存(329)、导出(341)
- 容量：宏录制空间提示 360-363（不足 / 即将不足 / 已达上限）

---

## 5. 系统配置项（140-186、600-624）

### 5.1 按键响应时间（140 + 149「档」，配置键 `key_respondtime`，function.key_respondtime=1）

5 档，各档实际延迟（语言 600-624）：

| 档位 | 标题 id | 有线(USB) | 2.4G | 蓝牙 |
|---|---|---|---|---|
| 一档 | 600 | 2-3 ms | 5-6 ms | 12-13 ms |
| 二档 | 605 | 5-6 ms | 7-9 ms | 15-16 ms |
| 三档 | 610 | 8-9 ms | 10-12 ms | 18-19 ms |
| 四档 | 615 | 13-14 ms | 15-17 ms | 23-24 ms |
| 五档 | 620 | 17-18 ms | 19-21 ms | 27-28 ms |

每档附带说明（602-604 / 607-609 / 612-614 / 617-619 / 622-624）：参数会因设备与环境干扰变化；轴体不同，延迟过低可能引起按键连击，出现连击请调高延迟设定。

### 5.2 休眠时间（141，配置键 `sleep_time`，function.sleep_time=1）

| id | 选项 |
|---|---|
| 142 | 不休眠 |
| 143 | 1分钟 |
| 144 | 5分钟 |
| 145 | 30分钟 |

（二进制中紧邻 `sleep_time` 的字符串字面量为 `2`，推测默认值 = 5 分钟；同法 `keyboard_layout` 邻接 `1`、`fn_layer` 邻接 `0`，均需运行时确认。）

### 5.3 禁用键（配置键 `disable_win` / `disable_altf4` / `disable_alttab`）

| id | 项 |
|---|---|
| 160 | 禁用 Window键 |
| 161 | 禁用 ALT + F4 |
| 162 | 禁用 ALT + TAB |

### 5.4 重置 / 恢复出厂

| id | 文案 |
|---|---|
| 152 / 166 | 重置键盘；确认文案 165「重置键盘将清除键盘所有数据，是否继续?」 |
| 153 / 168 | 恢复出厂；确认文案 167「恢复出厂设置将清除所有数据，是否继续?」 |

（另见语言 37「重置」通用按钮文案。）

### 5.5 其他系统项

| id | 项 | 说明 |
|---|---|---|
| 150 | 语言 | `config.xml`：`default_lan=2052`，可选 2052 简中 / 1033 英文 / 1028 繁体 |
| 151 | 开机启动 | 自启动开关 |
| 156 | 驱动更新 | 175「当前已经是最新版本」/176「检测到有新版驱动，是否更新?」 |
| 157 | 固件更新 | 177「当前固件已是最新版本…仍要刷固件?」；180-182 升级注意事项；183 警告；185 升级 /186 取消 |
| 170 | 关闭主窗口 | 关闭窗口 |
| 171 | 最小到托盘，不退出程序 | 托盘行为 |
| 172 | 退出程序 | |
| 10 / 11 | 配置 / 退出 | 主菜单按钮 |

### 5.6 `t_config_data` 配置键全表（来自 DeviceDriver.exe 字符串）

| key | 相邻字面量（疑似默认值） | 含义 |
|---|---|---|
| `version` | `1.0.1` | 配置版本 |
| `keyboard_layout` | `1` | 键位布局编号 |
| `fn_layer` | `0` | Fn 层开关/状态 |
| `fn_switch` | — | Fn 开关功能（语言 292） |
| `lightmode` | — | 当前灯光模式 |
| `sleep_time` | `2` | 休眠时间档位 |
| `key_respondtime` | — | 按键响应时间档位 |
| `sleep_light` | — | 休眠后灯效策略 |
| `userlight` | — | 当前用户灯光方案 |
| `customlight` | — | 当前自定义灯光方案 |
| `customlight_run` | — | 自定义灯效是否运行 |
| `gamemode` | — | 游戏模式（对应键 `GAME`，`code=0x97`） |
| `disable_alttab` / `disable_altf4` / `disable_win` | — | 三个禁用开关 |
| `default_color1..8` | `8331093, 4114939, 65280, 16776960, 255, 14237951, (缺省), 16777215` | 调色板 8 个默认色（十进制 RGB，例：65280=绿、16776960=黄、255=蓝、16777215=白） |

> 另有两个 32 字节十六进制串 `12345500072bf3390c79f01004dabcde`、`1234560247a0619f07548fb1b8abcedf` 与库名格式串 `db\%s_datav1.db`（UTF-16）同处，推测为配置库文件名模板与加密/标识密钥。

---

## 6. SQLite 数据模型（`DeviceDriver.exe` 内嵌建表语句原文）

库名模板：`db\%s_datav1.db`（`%s` 由运行时填入）。以下为 `CREATE TABLE IF NOT EXISTS` 原文整理（含全部索引）：

```sql
CREATE TABLE t_config_data(config_id INTEGER PRIMARY KEY AUTOINCREMENT,
                           profile INTEGER, key TEXT, value TEXT);
-- 无显式索引（按 profile+key 查询）

CREATE TABLE t_profile_data(profile INTEGER PRIMARY KEY AUTOINCREMENT,
                            name TEXT, status INTEGER, app TEXT, type INTEGER);
CREATE INDEX profileindex ON t_profile_data(profile);

CREATE TABLE t_key_macro_data(key_id INTEGER PRIMARY KEY AUTOINCREMENT,
                              profile INTEGER, fn_layer INTEGER, key_code INTEGER,
                              layout_value INTEGER, layout_desc TEXT,
                              macro_type INTEGER, macro_value INTEGER,
                              macro_value2 INTEGER, macro_value3 INTEGER, macro_desc TEXT);
CREATE INDEX keyindex ON t_key_macro_data(key_id);

CREATE TABLE t_key_otherdata(macro_value INTEGER PRIMARY KEY AUTOINCREMENT,
                             macro_desc TEXT, param TEXT, type INTEGER);
CREATE INDEX otheridindex ON t_key_otherdata(macro_value);

CREATE TABLE t_macro_data(macro_id INTEGER PRIMARY KEY AUTOINCREMENT,
                          play_times INTEGER, delay_type INTEGER, delay_time INTEGER,
                          link_count INTEGER, name TEXT);
CREATE INDEX macroidindex ON t_macro_data(macro_id);

CREATE TABLE t_macrorecord(record_id INTEGER PRIMARY KEY AUTOINCREMENT,
                           macro_id INTEGER, type INTEGER, record_index INTEGER,
                           desc TEXT, value INTEGER, delay_time INTEGER);
CREATE INDEX macrorecordindex ON t_macrorecord(record_id);

CREATE TABLE t_light_data(light_id INTEGER PRIMARY KEY AUTOINCREMENT,
                          profile INTEGER, name TEXT, mode INTEGER,
                          brightness INTEGER, speed INTEGER, direction INTEGER,
                          colorful INTEGER, colorindex INTEGER, color_value INTEGER,
                          config_func INTEGER, reserved INTEGER, status INTEGER);
CREATE INDEX lightindex ON t_light_data(light_id);

CREATE TABLE t_userlight_data(userlight_id INTEGER PRIMARY KEY AUTOINCREMENT,
                              profile INTEGER, name TEXT, speed INTEGER,
                              brightness INTEGER, status INTEGER);
CREATE INDEX userlightindex ON t_userlight_data(userlight_id);

CREATE TABLE t_userlightrgb_data(userlightrgb_id INTEGER PRIMARY KEY AUTOINCREMENT,
                                 profile INTEGER, userlight_id INTEGER,
                                 key_code INTEGER, key_rgb INTEGER);
CREATE INDEX userlightrgbindex ON t_userlightrgb_data(userlightrgb_id);

CREATE TABLE t_customlight_data(customlight_id INTEGER PRIMARY KEY AUTOINCREMENT,
                                profile INTEGER, name TEXT, speed INTEGER,
                                brightness INTEGER, status INTEGER);
CREATE INDEX customlightindex ON t_customlight_data(customlight_id);

CREATE TABLE t_customrgb_data(customrgb_id INTEGER PRIMARY KEY AUTOINCREMENT,
                              customlight_id INTEGER, keycode INTEGER, rgbvalue INTEGER,
                              light_mode INTEGER, colortype INTEGER, light_type INTEGER);
CREATE INDEX customrgbindex ON t_customrgb_data(customrgb_id);

CREATE TABLE t_musiclayer_data(layer_id INTEGER PRIMARY KEY AUTOINCREMENT,
                               profile INTEGER, name TEXT, deviceindex INTEGER,
                               foremode INTEGER, fore_amplitude INTEGER,
                               backmode INTEGER, backb_right INTEGER, sel INTEGER);
CREATE INDEX musiclayerindex ON t_musiclayer_data(layer_id);

CREATE TABLE t_ledlayer_data(led_id INTEGER PRIMARY KEY AUTOINCREMENT,
                             profile INTEGER, type INTEGER, name TEXT,
                             frame_size INTEGER, file_dir TEXT, first_file TEXT);

CREATE TABLE t_ledframe_data(frame_id INTEGER PRIMARY KEY AUTOINCREMENT,
                             led_id INTEGER, name TEXT, delay_time INTEGER,
                             frame_index INTEGER, file_name TEXT);
```

### 6.1 关键 SQL（增删改查语句原文要点）

| 表 | 关键语句 |
|---|---|
| `t_config_data` | `SELECT value FROM t_config_data WHERE profile=? AND key=?`；`INSERT INTO t_config_data(profile,key,value) VALUES(?,?,?)`；`UPDATE t_config_data SET value=? WHERE profile=? AND key=?` |
| `t_profile_data` | `INSERT INTO t_profile_data(name,status,app,type) VALUES(?,?,?,?)`；`UPDATE t_profile_data SET name=? WHERE profile=?`；`UPDATE t_profile_data SET status=?`（清全部）/`... WHERE profile=?`；`SELECT profile FROM t_profile_data WHERE status=?`；`DELETE FROM t_profile_data WHERE profile=?` |
| `t_key_macro_data` | 按 `(profile,fn_layer,key_code)` SELECT/DELETE；`DELETE ... WHERE profile=?`（随配置档删除）；`DELETE ... WHERE macro_type=? AND macro_value=?`（删宏时解绑） |
| `t_key_otherdata` | `INSERT INTO t_key_otherdata(macro_desc,param,type) VALUES(?,?,?)`；`SELECT ... WHERE macro_value=?` |
| `t_light_data` | `SELECT ... WHERE profile=? AND mode=?`；`UPDATE t_light_data SET brightness=?,speed=?,direction=?,colorful=?,colorindex=?,color_value=?,config_func=?,reserved=? WHERE profile=? AND mode=?`；`UPDATE ... SET status=? WHERE profile=?` / `... AND mode=?`；`SELECT mode FROM t_light_data WHERE profile=? AND status=?` |
| `t_userlight*` | 方案 CRUD + `INSERT INTO t_userlightrgb_data(profile,userlight_id,key_code,key_rgb) VALUES(?,?,?,?)`，`DELETE ... WHERE userlight_id=?` |
| `t_custom*` | 方案 CRUD + `INSERT INTO t_customrgb_data(customlight_id,keycode,rgbvalue,light_mode,colortype,light_type) VALUES(?,?,?,?,?,?)`；`DELETE ... WHERE customlight_id=? AND keycode=?` |
| `t_macro*` | `INSERT INTO t_macro_data(play_times,delay_type,delay_time,link_count,name) VALUES(?,?,?,?,?)`；`UPDATE ... SET play_times=?,delay_type=?,delay_time=? WHERE macro_id=?`；`INSERT INTO t_macrorecord(macro_id,type,record_index,desc,value,delay_time) VALUES(?,?,?,?,?,?)`；`SELECT * FROM t_macrorecord WHERE macro_id=? ORDER BY record_index ASC` |
| `t_led*` | `INSERT INTO t_ledlayer_data(profile,type,name,frame_size,file_dir,first_file)`；`INSERT INTO t_ledframe_data(led_id,name,delay_time,frame_index,file_name)`；`SELECT * ... ORDER BY frame_index ASC`；`DELETE FROM t_ledlayer_data` / `t_ledframe_data`（清库） |
| `t_musiclayer_data` | 方案 CRUD + `UPDATE ... SET deviceindex=?,foremode=?,fore_amplitude=?,backmode=?,backb_right=? WHERE layer_id=?`；`UPDATE ... SET sel=? WHERE profile=?`（当前选中律动） |

> 任务清单中未列出但确实存在的两张表：`t_key_otherdata`（预设功能参数：程序/网站/文件路径等）与 `t_ledframe_data`（TFT 帧）。

---

## 7. 键位布局数据（可直接用于 UI）

来源：`layouts/rgb-keyboard.xml`，`col_count=26`、`row_count=6`，画布 `xpos=385, ypos=150, width=800, height=300`（相对驱动窗口），键图 `skins/theme1/keyboard/img_keyboard_layout.png`，底色 `bk_color=CD7A00`。

统计：

- 共 **112** 个 `<key>`：标准键 104 个 + 特殊键 8 个（`BTPAIR 0x95`、`LEDOFF 0x96`、`GAME 0x97`、`CALC 0x98`、`LOCK 0x94`、`VOLDEC 0xEA`、`MUTE 0xEB`、`VOLINC 0xE9`）。
- 每行键数：row0=23、row1=21、row2=21、row3=17、row4=17、row5=13。
- `key_index` 与 `light_index` 范围均为 1..124（有空洞，112 键不连续编号），**同一键的 key_index 与 light_index 在本布局中完全一致**。
- `row_col` 格式 `行#列`（行 0-5，列 0-25，26 列），列号有跳变（例如 row3 的 Enter 在 `3#15`，LOCK 在 `3#25`）。
- `fnlayer_disable` 全为 `0`。
- `code` 为 HID usage（如 `0x29`=Esc、`0x14`=Q、`0x2c`=Space、`0xAF`=Fn），可直接用于 macOS HID 映射。

| # | name | code | row_col | key_index | light_index | rect(l,t,w,h) | fnlayer_disable |
|---|------|------|---------|-----------|-------------|---------------|----------------|
| 1 | Esc | `0x29` | 0#1 | 1 | 1 | 11,29,30,30 | 0 |
| 2 | F1 | `0x3a` | 0#2 | 2 | 2 | 81,29,30,30 | 0 |
| 3 | F2 | `0x3b` | 0#3 | 3 | 3 | 115,29,30,30 | 0 |
| 4 | F3 | `0x3c` | 0#4 | 4 | 4 | 150,29,30,30 | 0 |
| 5 | F4 | `0x3d` | 0#5 | 5 | 5 | 184,29,30,30 | 0 |
| 6 | F5 | `0x3e` | 0#6 | 6 | 6 | 236,29,30,30 | 0 |
| 7 | F6 | `0x3f` | 0#7 | 7 | 7 | 271,29,30,30 | 0 |
| 8 | F7 | `0x40` | 0#8 | 8 | 8 | 305,29,30,30 | 0 |
| 9 | F8 | `0x41` | 0#9 | 9 | 9 | 339,29,30,30 | 0 |
| 10 | F9 | `0x42` | 0#10 | 10 | 10 | 391,29,30,30 | 0 |
| 11 | F10 | `0x43` | 0#11 | 11 | 11 | 426,29,30,30 | 0 |
| 12 | F11 | `0x44` | 0#12 | 12 | 12 | 461,29,30,30 | 0 |
| 13 | F12 | `0x45` | 0#13 | 13 | 13 | 495,29,30,30 | 0 |
| 14 | PRINT | `0x46` | 0#16 | 112 | 112 | 538,29,30,30 | 0 |
| 15 | SCROOL | `0x47` | 0#17 | 113 | 113 | 572,29,30,30 | 0 |
| 16 | pause | `0x48` | 0#18 | 115 | 115 | 608,29,30,30 | 0 |
| 17 | BTPAIR | `0x95` | 0#19 | 71 | 71 | 658,36,20,20 | 0 |
| 18 | LEDOFF | `0x96` | 0#20 | 89 | 89 | 683,36,20,20 | 0 |
| 19 | GAME | `0x97` | 0#21 | 107 | 107 | 706,36,20,20 | 0 |
| 20 | CALC | `0x98` | 0#22 | 109 | 109 | 729,36,20,20 | 0 |
| 21 | VOLDEC | `0xEA` | 0#23 | 15 | 15 | 753,28,10,35 | 0 |
| 22 | MUTE | `0xEB` | 0#24 | 16 | 16 | 766,28,12,35 | 0 |
| 23 | VOLINC | `0xE9` | 0#25 | 14 | 14 | 780,28,10,35 | 0 |
| 24 | ~` | `0x35` | 1#1 | 19 | 19 | 11,77,30,30 | 0 |
| 25 | !1 | `0x1e` | 1#2 | 20 | 20 | 46,77,30,30 | 0 |
| 26 | @2 | `0x1f` | 1#3 | 21 | 21 | 81,77,30,30 | 0 |
| 27 | #3 | `0x20` | 1#4 | 22 | 22 | 115,77,30,30 | 0 |
| 28 | $4 | `0x21` | 1#5 | 23 | 23 | 150,77,30,30 | 0 |
| 29 | %5 | `0x22` | 1#6 | 24 | 24 | 184,77,30,30 | 0 |
| 30 | ^6 | `0x23` | 1#7 | 25 | 25 | 219,77,30,30 | 0 |
| 31 | &7 | `0x24` | 1#8 | 26 | 26 | 253,77,30,30 | 0 |
| 32 | *8 | `0x25` | 1#9 | 27 | 27 | 287,77,30,30 | 0 |
| 33 | (9 | `0x26` | 1#10 | 28 | 28 | 321,77,30,30 | 0 |
| 34 | )0 | `0x27` | 1#11 | 29 | 29 | 356,77,30,30 | 0 |
| 35 | _- | `0x2d` | 1#12 | 30 | 30 | 391,77,30,30 | 0 |
| 36 | += | `0x2e` | 1#13 | 31 | 31 | 426,77,30,30 | 0 |
| 37 | Backspace | `0x2a` | 1#15 | 103 | 103 | 461,77,64,30 | 0 |
| 38 | Insert | `0x49` | 1#16 | 116 | 116 | 538,77,30,30 | 0 |
| 39 | Home | `0x4a` | 1#17 | 117 | 117 | 572,77,30,30 | 0 |
| 40 | PgUp | `0x4b` | 1#18 | 118 | 118 | 608,77,30,30 | 0 |
| 41 | Num | `0x53` | 1#19 | 32 | 32 | 651,77,30,30 | 0 |
| 42 | // | `0x54` | 1#20 | 33 | 33 | 686,77,30,30 | 0 |
| 43 | * | `0x55` | 1#21 | 34 | 34 | 720,77,30,30 | 0 |
| 44 | - | `0x56` | 1#22 | 122 | 122 | 754,77,30,30 | 0 |
| 45 | Tab | `0x2b` | 2#1 | 37 | 37 | 11,112,49,30 | 0 |
| 46 | Q | `0x14` | 2#2 | 38 | 38 | 63,112,30,30 | 0 |
| 47 | W | `0x1a` | 2#3 | 39 | 39 | 98,112,30,30 | 0 |
| 48 | E | `0x8` | 2#4 | 40 | 40 | 133,112,30,30 | 0 |
| 49 | R | `0x15` | 2#5 | 41 | 41 | 167,112,30,30 | 0 |
| 50 | T | `0x17` | 2#6 | 42 | 42 | 202,112,30,30 | 0 |
| 51 | Y | `0x1c` | 2#7 | 43 | 43 | 237,112,30,30 | 0 |
| 52 | U | `0x18` | 2#8 | 44 | 44 | 272,112,30,30 | 0 |
| 53 | I | `0xc` | 2#9 | 45 | 45 | 306,112,30,30 | 0 |
| 54 | O | `0x12` | 2#10 | 46 | 46 | 340,112,30,30 | 0 |
| 55 | P | `0x13` | 2#11 | 47 | 47 | 375,112,30,30 | 0 |
| 56 | {[ | `0x2f` | 2#12 | 48 | 48 | 409,112,30,30 | 0 |
| 57 | }} | `0x30` | 2#13 | 49 | 49 | 444,112,30,30 | 0 |
| 58 | \|\ | `0x31` | 2#14 | 67 | 67 | 478,112,47,30 | 0 |
| 59 | Del | `0x4c` | 2#15 | 119 | 119 | 538,112,30,30 | 0 |
| 60 | End | `0x4d` | 2#16 | 120 | 120 | 572,112,30,30 | 0 |
| 61 | PgDn | `0x4e` | 2#17 | 121 | 121 | 608,112,30,30 | 0 |
| 62 | 7 | `0x5f` | 2#18 | 50 | 50 | 651,112,30,30 | 0 |
| 63 | 8 | `0x60` | 2#19 | 51 | 51 | 686,112,30,30 | 0 |
| 64 | 9 | `0x61` | 2#20 | 52 | 52 | 720,112,30,30 | 0 |
| 65 | + | `0x57` | 2#21 | 123 | 123 | 754,112,30,64 | 0 |
| 66 | CapsLock | `0x39` | 3#1 | 55 | 55 | 11,146,56,30 | 0 |
| 67 | A | `0x4` | 3#2 | 56 | 56 | 72,146,30,30 | 0 |
| 68 | S | `0x16` | 3#3 | 57 | 57 | 106,146,30,30 | 0 |
| 69 | D | `0x7` | 3#4 | 58 | 58 | 141,146,30,30 | 0 |
| 70 | F | `0x9` | 3#5 | 59 | 59 | 176,146,30,30 | 0 |
| 71 | G | `0xa` | 3#6 | 60 | 60 | 210,146,30,30 | 0 |
| 72 | H | `0xb` | 3#7 | 61 | 61 | 244,146,30,30 | 0 |
| 73 | J | `0xd` | 3#8 | 62 | 62 | 279,146,30,30 | 0 |
| 74 | K | `0xe` | 3#9 | 63 | 63 | 313,146,30,30 | 0 |
| 75 | L | `0xf` | 3#10 | 64 | 64 | 347,146,30,30 | 0 |
| 76 | :; | `0x33` | 3#11 | 65 | 65 | 382,146,30,30 | 0 |
| 77 | "' | `0x34` | 3#12 | 66 | 66 | 417,146,30,30 | 0 |
| 78 | Enter | `0x28` | 3#15 | 85 | 85 | 452,146,73,30 | 0 |
| 79 | LOCK | `0x94` | 3#25 | 124 | 124 | 620,150,23,23 | 0 |
| 80 | 4 | `0x5c` | 3#19 | 68 | 68 | 651,146,30,30 | 0 |
| 81 | 5 | `0x5d` | 3#20 | 69 | 69 | 686,146,30,30 | 0 |
| 82 | 6 | `0x5e` | 3#21 | 70 | 70 | 720,146,30,30 | 0 |
| 83 | Shift_L | `0xe1` | 4#0 | 73 | 73 | 11,181,75,30 | 0 |
| 84 | Z | `0x1d` | 4#2 | 74 | 74 | 90,181,30,30 | 0 |
| 85 | X | `0x1b` | 4#3 | 75 | 75 | 124,181,30,30 | 0 |
| 86 | C | `0x6` | 4#4 | 76 | 76 | 159,181,30,30 | 0 |
| 87 | V | `0x19` | 4#5 | 77 | 77 | 194,181,30,30 | 0 |
| 88 | B | `0x5` | 4#6 | 78 | 78 | 228,181,30,30 | 0 |
| 89 | N | `0x11` | 4#7 | 79 | 79 | 262,181,30,30 | 0 |
| 90 | M | `0x10` | 4#8 | 80 | 80 | 296,181,30,30 | 0 |
| 91 | ,< | `0x36` | 4#9 | 81 | 81 | 330,181,30,30 | 0 |
| 92 | .> | `0x37` | 4#10 | 82 | 82 | 364,181,30,30 | 0 |
| 93 | /? | `0x38` | 4#11 | 83 | 83 | 399,181,30,30 | 0 |
| 94 | Shift_R | `0xe5` | 4#13 | 84 | 84 | 434,181,91,30 | 0 |
| 95 | ↑ | `0x52` | 4#17 | 101 | 101 | 572,181,30,30 | 0 |
| 96 | 1 | `0x59` | 4#19 | 86 | 86 | 651,181,30,30 | 0 |
| 97 | 2 | `0x5a` | 4#20 | 87 | 87 | 686,181,30,30 | 0 |
| 98 | 3 | `0x5b` | 4#21 | 88 | 88 | 720,181,30,30 | 0 |
| 99 | Enter | `0x58` | 4#22 | 106 | 106 | 754,181,30,64 | 0 |
| 100 | Ctrl_L | `0xe0` | 5#0 | 91 | 91 | 11,215,40,30 | 0 |
| 101 | Win_L | `0xe3` | 5#1 | 92 | 92 | 54,215,40,30 | 0 |
| 102 | Alt_L | `0xe2` | 5#2 | 93 | 93 | 98,215,40,30 | 0 |
| 103 | Space | `0x2c` | 5#6 | 94 | 94 | 141,215,214,30 | 0 |
| 104 | Alt_R | `0xe6` | 5#10 | 95 | 95 | 357,215,40,30 | 0 |
| 105 | Fn | `0xAF` | 5#11 | 96 | 96 | 400,215,40,30 | 0 |
| 106 | APP | `0x65` | 5#12 | 97 | 97 | 443,215,40,30 | 0 |
| 107 | Ctrl_R | `0xE4` | 5#13 | 98 | 98 | 485,215,40,30 | 0 |
| 108 | ← | `0x50` | 5#16 | 99 | 99 | 538,215,30,30 | 0 |
| 109 | ↓ | `0x51` | 5#17 | 100 | 100 | 572,215,30,30 | 0 |
| 110 | → | `0x4f` | 5#18 | 102 | 102 | 608,215,30,30 | 0 |
| 111 | 0 | `0x62` | 5#20 | 104 | 104 | 651,215,65,30 | 0 |
| 112 | . | `0x63` | 5#21 | 105 | 105 | 720,215,30,30 | 0 |

---

## 8. 连接模式限制汇总

| 场景 | 可设置项 | 不可设置项 |
|---|---|---|
| USB 有线（`mode=0`，MI_00） | `menu` 全部：宏、灯光模式、用户灯光、**自定义灯光**、音乐律动、系统配置 | 侧灯、TFT（本机型属性=0） |
| 2.4G（`mode=2`，MI_03） | `menu_wireless`：宏、灯光模式、用户灯光、音乐律动、系统配置 | **自定义灯光**（属性缺失）、侧灯、TFT |
| 蓝牙 | 无（语言 62 明确提示改用 USB 或 2.4G） | 全部键盘设置 |

---

## 9. 复刻 macOS 版的落地要点（待办映射）

1. **必须实现**：配置档（含按应用切换）、改键（顶层/Fn 层 + 290-298 四种输出模式）、宏（录制/播放 6 种方式/1-255 循环）、灯光模式（亮度/速度/方向/多彩/颜色）、用户灯光、自定义灯光（仅 USB）、音乐律动、系统配置（响应时间 5 档、休眠 4 档、3 个禁用键、重置/恢复出厂、开机启动、语言 3 种）。
2. **按机型隐藏**：侧灯（sidelight=0）、TFT 屏（screen=0）、屏光联动（120，依赖屏）。
3. **数据层**：直接复用 §6 的 13 张表结构即可与官方驱动数据同构（便于导入导出互通）。
4. **待运行时确认项**：配置档数量上限、组 A/组 B 模式表归属、`sleep_time`/`key_respondtime` 默认档位、`default_color7` 取值。
