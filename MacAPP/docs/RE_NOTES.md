# GS3104T-PRO 驱动逆向记录（由 lead 维护）

## 1. 包结构

- `extracted/GS3104T-PRO驱动+固件 20241015/驱动程序-GS3104T-PRO Driver-1.0.0.3.exe`
  - Inno Setup 6.1.0 安装包 → 用 `innoextract -d driver_app <exe>` 解出
- `driver_app/app/DeviceDriver.exe` — 主程序，PE32 (Win32)，**MFC/C++**（不是 Delphi）
  - 依赖 `mfc140u.dll` / `msvcp140.dll` / `mui.dll`（自绘 UI 库）
  - 通过 `HidD_SetFeature` + `DeviceIoControl(IOCTL=0xB0192, GET_FEATURE)` 与键盘通信
  - 配置存 SQLite（表：`t_profile_data` `t_key_macro_data` `t_macro_data` `t_light_data`
    `t_customlight_data` `t_customrgb_data` `t_userlight_data` `t_userlightrgb_data`
    `t_ledlayer_data` `t_musiclayer_data` `t_config_data`）
- `driver_app/app/config.xml` — 设备匹配信息
- `driver_app/app/layouts/rgb-keyboard.xml` — 键位布局（26x6，含 key_index/light_index）
- `driver_app/app/language/{1033,2052,1028}.lan` — 功能清单（UTF-16，[SECTION] 格式）
- `extracted/firmware/...` — Sonix ISP 固件升级工具（SN32F290，VID 0x0C45 PID 0x8009/0x8801，
  CheckDeviceCmd=AA42895AFF7162CC），**固件升级不是本项目重点**（可后置）

## 2. 设备（本机已连接，2.4G 接收器）

- VID=0x05AC(1452) PID=0x024F(591)，产品名 `GS3104T-PRO 2.4G`，bcdDevice=0x0136(310)
- config.xml：USB 模式 MI_00，2.4G 模式 MI_03（`VID_05AC&PID_024F&MI_03`）
- USB 接口：MI_00 键盘(HID boot,1/1)、MI_01 鼠标(1/2)、MI_02 消费键(page12)、
  MI_03/MI_04 厂商自定义
- **厂商配置通道**（ioreg 实测）：
  - UsagePage=0xFF60(65376) Usage=0x61(97) 的 HID 服务，两个：
    - 64 字节 Input(usage 0x62) + 64 字节 Output(usage 0x63)  ← 驱动用这个（0x41=65 字节传输）
    - 32 字节 Input + 32 字节 Output
  - ReportDescriptor(64B) = `0660ff 0961 a101 0962 1500 26ff00 9540 7508 8102 0963 1500 26ff00 9540 7508 9102 c0`
  - **注意：描述符里没有 Feature 报告，只有 Input/Output**。macOS 侧用
    `IOHIDDeviceSetReport(kIOHIDReportTypeOutput)` / input 回调或 `GetReport(Input)`。

## 3. 传输层（DeviceDriver.exe，imagebase 0x400000）

关键函数（VA）：

| 地址 | 作用 |
|---|---|
| `0x450990` | LoadLibrary("hid.dll") + GetProcAddress 解析 HidD_*，指针存 `0x5950xx` |
| `0x4512e0` | `HidD_SetFeature(handle, buf, 0x41)`，成功返回 0x41，失败 -1 |
| `0x451380` | `DeviceIoControl(handle, 0xB0192 /*GET*/, buf, len, buf, len, ...)` 读响应 |
| `0x44ed70` | **发送函数 A**（thiscall，参数 = (buf, len=0x41, flag)，`ret 0xc`） |
| `0x44ef60` | **发送函数 B**（len>0x41 时分片，每片 0x40，最多重试 10 次；用于上传宏/灯光大数据） |
| `0x413440` | 取单例设备对象（0x595144），返回 eax 给 ecx 用 |

发送函数 A 行为（0x44ed70）：
1. `this` 不可用 → return 0
2. `Sleep([this+0x30])`（cmd_delaytime，config.xml=35ms）
3. 局部 `report[0x41]` 清零 → `report[0]=0`(报告ID)，`report[1..64] = buf[0..63]`
4. `HidD_SetFeature(handle, report, 0x41)`
5. 若 flag≠0 → `DeviceIoControl(GET)` 读回同一 buffer，检查 `report[4] == 1`（即 buf[3]==1）才算成功

命令构造模式（调用者处，栈上 `ebp-0x54` 起 64 字节缓冲）：
- `memset(ebp-0x53, 0, 0x40)` 然后 `mov word [ebp-0x54], <imm>` → buf[0], buf[1]
- 已观察到的命令字（buf[0..1]）：
  - `04 18` （flag=1，疑似"读取/进入配置"）
  - `04 17` buf[2]=1 buf[8]=1
  - `04 13` buf[8]=1
  - `04 02` （flag=1，出现在写流程收尾）
  - `04 F0`
  - `04 20` buf[8]=3 或 8（0x428000：写 per-key RGB，长度 0x200/0xC0，之后发 `04 02`）
  - `00 01` （0x4142c8，随后填充 disable_win/altf4/alttab 相关字节并发送）
  - 某些命令 buf[14..15] = `AA 55` 校验标记（0x42b16a `mov word [ebp-0x46],0x55aa`）
- 0x428000 = 上传键位灯光（RGB，每键 3 或 4 字节，0x7ac 决定 RGB 还是单色）
- 0x44ef60 的 6 个调用点：0x428070、0x428283、0x4282af（灯光）、0x4329d0、0x432b2b、0x432b57
- 0x44ed70 的调用点约 41 处（0x14285,0x142a7,0x14428,0x14452,0x1863b,0x1866c,0x18d3a,0x18dba,
  0x18e2a,0x23102,0x2319f,0x2336b,0x23b58,0x23b86,0x23c0d,0x23c37,0x2b00a,0x2b0f4,0x2b112,
  0x2b17a,0x2b1a4,0x2b1ce,0x2d6e0,0x2db5a,0x2db7a,0x2dba8,0x33fd8,0x33ff6,0x34029,0x34053,
  0x3407d,0x4b7e8,0x4b806,0x4b84a,0x4b874,0x4b89e,0x4b945,0x4b976,0x4bc0b,0x4bc87,0x4bcf3）

## 4. 分析工具

- `innoextract`（已 brew 安装，用 NJU 镜像）
- Python3 + `capstone`（已 pip 安装）
- 反汇编脚本模式：解析 PE section → `.text` RVA/RAW → capstone 32 位
