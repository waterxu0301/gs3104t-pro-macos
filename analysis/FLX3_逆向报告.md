# GANSS FLX3 鼠标协议逆向报告（阶段 0 · 基于 WebHID 前端静态逆向）

> 逆向对象：`https://driver.yuandaxin-tech.com/GANSS/FLX3_BK_2K/`
> 方法：下载前端打包 JS（`index-DjqHA2FO.js` 1.0MB 主 chunk + `DeviceView-CnPoKMyr.js` 1.1MB 页面 chunk），
> 从未混淆的 Vue3 编译产物中直接提取 WebHID 调用与报文构造逻辑。
> 证据强度：全部报文构造为前端源码级证据（非猜测），**但均未经实机写入验证**——实机验证在阶段 3 进行。
> 素材存档：`/tmp/flx3/`（app.js、DeviceView.js、index.html、style.css），建议拷贝入仓库 `analysis/flx3/`。

---

## 1. 设备识别

| 项 | 值 |
|---|---|
| VID | `0x04F3` (1267，Elan/Synaptics 方案商 ID) |
| PID | **622 (0x276) = USB 有线**，**623 (0x277) = 2.4G 接收器**，其余（含 623 之外的值）= BT |
| 通道选择 | 前端 `filters:[{vendorId:1267}]`，`collections.length>2` 的接口被选为配置接口 |
| 连接模式判定 | `productId===623 → "2.4G"`，`622 → "USB"`，否则 `"BT"` |

## 2. 传输模型（与 GS3104T 键盘完全不同）

FLX3 使用**标准 Feature Report + Report ID** 模型（键盘是无 Report ID 的厂商自定义模型）：

- **下行（配置写入）**：`sendFeatureReport(reportId=6, data)`，data 为 **31 字节**
- **上行（状态查询）**：`receiveFeatureReport(reportId=5)` → 31 字节，`getUint8(1)` 为命令执行状态（1=成功）
- **主动上报（异步 Input）**：`oninputreport`，**reportId=4**，8 字节状态包（见 §3）
- 每条命令有 **commandSeq 序号**（`(seq+1)%256`，初始 1），放在 data[1]

### 校验和（前端函数 `setCheckSum`，逐字还原）

```js
function setCheckSum(data) {
  let sum = 6;
  data.forEach((v, i) => { if (i !== 3) sum += v; });   // 跳过 index 3
  sum = sum & 255;
  data.splice(3, 0, sum);                                // 校验和插入 index 3
}
```
即：命令数组原为 `[cmd, seq, subcmd, payload...]`，发送前把「6 + 除 index3 外全部字节之和 & 0xFF」
插入到 index 3，最终 **31 字节**（不足补 0 或 0xFF，取决于命令；宏块补 0，其余补 255）。

### 命令重试模型

`sendCommand(reportId=6, data)`：最多重试 3 次；每次发送前延迟 `100 + attempt*50` ms；
发送后 `receiveFeatureReport(6)` 读回状态，`getUint8(1)==1` 判成功；失败重试。

## 3. 设备状态（reportId=4 主动上报，8 字节）

| 偏移 | 含义 |
|---|---|
| 0 | linkStatus |
| 1 | currentLevel（当前 DPI 档位） |
| 2 | currentReportRate |
| 3 | batteryLevel（电量 %） |
| 4 | batteryStatus |
| 5 | lightEffectMode |
| 7 | maxReportRate（1/2/4/8 → 决定可选回报率档位） |
| 8 | sensorType（决定 DPI 换算与最大 DPI，见 §6） |

## 4. 按键映射协议（reportId=6，cmd=1，单包/双包）

**按键动作记录为 3 字节 `[type, param, value]`**，与键盘 4 字节记录不同：

| type | 含义 | 实例 |
|---|---|---|
| `16` | 鼠标键 | `[16,1,0]`左键 `[16,2,0]`右键 `[16,4,0]`中键 `[16,8,0]`后退 `[16,16,0]`前进 |
| `48` | 火力键 | `[48,interval_ms,次数]`，次数 0=按住持续开火 |
| `64` | DPI 功能 | `[64,1,0]`DPI循环 `[64,2,0]`DPI+ `[64,3,0]`DPI- |
| `80` | DPI 锁定 | `[80,档位,0]`（如 `[80,11,0]`=锁定1200） |
| `96` | 特殊 | `[96,0,0]`禁用按键，`[96,4,0]`灯光开关 |
| `112` | 键盘组合键 | `[112,modifier_mask,HID_usage]`（mask: ctrl1/shift2/alt4/win8，同键盘） |
| `128` | 多媒体 | `[128,131,1]`播放暂停 `[128,182,0]`上一曲 `[128,181,0]`下一曲 `[128,183,0]`停止 `[128,146,1]`计算器（第二字节为 usage 高位组，见下） |
| `144` | 宏引用 | `[144,(H<<4)|(slot&15),repeat]`：H=执行方式(1按住循环/2指定次数/4任意键停止)，slot=宏槽位，repeat=次数（0=无限） |

多媒体键码实例：`[128,131,1]`、`[128,182,0]` — 182/131 ≈ usage 页拆分（182=0xB6 扫描下一曲 0x0B6？）
**注意**：128 类第二字节与第三字节的精确拆分规则需实机对照，前端只给了查表值（见 §8 表）。

**包格式**（按键 ≤9 个走单包，>9 双包；FLX3 是 6 键所以永远单包）：

```
[1, seq, 模式(1=单包/2=双包首包), 9×3字节按键记录..., 0xFF 填充至 31]
```

- 单包：`[1,seq,1]` + 按钮 1..9 各 3 字节；未配置按钮填 `[255,255,255]`，其余 0xFF 补齐
- **物理位置重排：payload 顺序 index3↔index4 交换**（前端的 3 号槽写物理按钮 4，4 号槽写物理按钮 3）
- 按钮 6 默认 DPI 循环；双包模式第二包 `[1,seq,3?]` 剩余按钮（按钮 6 特殊：首包若长度<21 追加 `[64,1,0]`）

**默认按键表**（FLX3）：1 左键 2 右键 3 中键 4 前进 5 后退 6 DPI循环。

## 5. 宏协议（reportId=6）——**完整还原，前端有逐字节注释级日志**

### 5.1 擦除宏区

```
[17, seq, 1, 255, 0...0 →31字节] + checksum
```

### 5.2 宏数据缓冲区结构

```
[9, 144, buttonIndex, eventCount, ...事件编码...]
```

**事件编码（每事件 3 字节）**，按事件 index 排序：

| 事件 | 编码 |
|---|---|
| 延迟 | `[delay>>8&15, delay&255, 0]`（delay 上限 4095ms） |
| 键按下/抬起 | `[flags, delay_next&255, keyCode]`：flags = `(下一事件延迟>>8&15) \| 128(若抬起) \| 16<<(类别)`。**keyCode 分类**：<145 普通(类别0)；145..231 修饰键(keyCode&7→mask，类别1)；240..244 鼠标键(F0..F4，类别2)；245/246/247=win/alt/tab类(类别3/4/5) |
| 光标移动 | `[64..81, delay&255, dx/dy]`：左0x40/右0x41/上0x50/下0x81 等，第三个字节带符号位移（1..127） |

**键盘键码表**（`N(key,keyCode)` 函数完整提取）：a=4..z=29，1=30..0=39，Enter=40，Esc=41，
Backspace=42，Tab=43，Space=44，F1=58..F12=69，Ctrl=224..Meta=227，方向键 79..82，
Numpad 84..99，音量 127..129，媒体 232..235，鼠标 240..244。与 HID 标准 usage 完全一致
（鼠标 240..244 为厂商私有扩展）。

### 5.3 宏分块下发

```
总数据长度 = len(buffer)-4（去掉头4字节）；每包 25 字节
[16, seq, (包号<<4)|(总包数&15), 1+本包有效长度, buttonIndex, ...25字节数据..., 0填充至31]
```
包间延迟 120ms；擦除后 100ms 再发首包。

### 5.4 宏执行方式（前端语义）

| executeType | 含义 | 编码进 `[144,...]` |
|---|---|---|
| 1 | 按住循环 | H=1, repeat=0 |
| 2 | 指定次数 | H=2, repeat=1..255 |
| 3 | 按任意键停止 | H=4, repeat=0 |

## 6. DPI 协议（reportId=6，cmd=2 / 3）

**传感器类型表**（`SENSOR_CONFIGS`，完整提取）：

| sensorType | 传感器 | DPI 档位表 | maxDPI |
|---|---|---|---|
| 17 | 3311 | 400/800/1600/3200/6400/12000… | 12000 |
| 149 (默认) | **3395** | 400/800/1600/3200/6400/26000… | 26000 |
| 80 | 3950 | …/30000 | 30000 |
| 32 | 3220 | …/8000 | 8000 |
| 18 | 3212 | …/4800 | 4800 |
| 9 | 3809 | …/6000 | 6000 |
| 6 | S205 | …/12800 | 12800 |
| 112 | OM70 | …/30000 | 30000 |

**写入 DPI（cmd=2）**：`[2, seq, 轴(2=X/18=Y), 当前档index, 启用档位mask(8bit), 8×(dpi_low,dpi_high)]`
- DPI→寄存器换算：sensor 149/80 → `floor(dpi/50)-1`；其他 → `floor(dpi/100)-1`
- 16bit 小端（low 在前）
- X/Y 独立设置：轴代码 X=2 / Y=18；非独立时两轴都写同值
- 启用档位 mask：`for i<levels: mask |= 1<<i`

**写入 DPI 颜色（cmd=3）**：`[3, seq, 1, 8×(R,G,B)]`（每档一个颜色，默认 8 档）

## 7. 性能与其他设置（reportId=6）

| cmd | 功能 | payload | 备注 |
|---|---|---|---|
| 4 | 回报率 | `[4, seq, 1, rate]` | rate: 1=1000Hz 2=500 4=250 8=125 17=2000 18=4000 20=8000（档位受 maxReportRate 上限约束） |
| 5 | LOD | `[5, seq, 1, lod]` | lod: 1=1mm 2=2mm |
| 7 | 电源管理 | `[7, seq, 1, sleepTime, moveWakeup(0/1), moveLighting(0/1)]` | sleepTime 1..15（分钟），timeRange 前端写死 15 |
| 8 | Sensor 高阶 | `[8, seq, 1, angleSnap, motionSync, rippleControl]` | 各 0/1 |
| 6 | 灯光 | `[6, seq, 1, 255, mode, brightness<<4\|speed, direction, R,G,B]` | brightness 1..4（左移4位），speed 1..3；mode: 0关/1混彩流光/2呼吸/3常亮/4霓虹/5跑马/6混彩常亮/7七彩波浪 |
| 15 | 恢复出厂 | `[15, seq, 1, 255, 0xFF...]` | 宏区也擦除 |

**灯光模式能力表**：mode 1/2/4/5/7 有 speed；3/6 有 brightness；全部无独立 color（除了常亮走 color 字段）。

## 8. 多媒体键完整查表（128 类第二/三字节）

```
播放暂停 [128,131,1] / 上一曲 [128,182,0] / 下一曲 [128,181,0] / 停止 [128,183,0]
计算器 [128,146,1] / 静音 [128,127,1]? / 音量+ / 音量- （前端查表部分值在 128 类展开时使用）
```
（精确值以后端宏表 `N()` 函数 + 实机抓包双重校验为准，见阶段 3 验证清单。）

## 9. 电池读取

电量来自 **reportId=4 主动上报**（§3 偏移 3/4），无需主动轮询；连接后设备周期上报。
前端状态栏显示电池百分比 + `batteryStatus`。

## 10. 与 GS3104T 键盘的协议对照表

| 维度 | GS3104T PRO 键盘 | FLX3 鼠标 |
|---|---|---|
| VID:PID | 05AC:024F（混叠 Apple） | 04F3:0276/0277（Elan 真实 ID） |
| 配置通道识别 | usage_page 0xFF60 + 产品名 | vendorId 过滤 + collections>2 |
| 报文模型 | 无 Report ID：65B feature / 33B 短报文 | Report ID 4/5/6，31B feature |
| 校验 | 短报文 32B 累加 & 255；feature 依赖 ACK[3]==1 | `(6+Σ字节(skip idx3))&255` 插入 idx3 + 读回状态[1]==1 |
| 命令头 | `04 xx` 业务命令 | `[cmd, seq, subcmd]` |
| 序号 | 无 | commandSeq 0..255 循环 |
| 重试 | 计划级（失败即停） | 命令级 3 次重试 |
| 键位记录 | 4B `[type,mask,usage,0]` | 3B `[type,param,value]` |
| 修饰键 mask | E0..E7 → 1..128 | ctrl1/shift2/alt4/win8（相同语义） |
| 宏 | `04 15` 变长分块（**未解码**） | **完整解码**（擦除+分块+事件编码） |
| 回读 | 键位层无 | 每命令可读回状态 + reportId4 主动上报 |
| 灯光 | 19 模式 5 档亮度速度 | 8 模式 4 档亮度 3 档速度 |
| 恢复出厂 | 无直接命令 | cmd=15 一键恢复 |

**结论**：两台设备协议族不同，但都通过 hidapi feature/output 通道工作，插件化的
`Transport` 抽象（open/write_feature/read_feature/write_output/read_input）完全够用，
差异全部封装在各插件 `driver.py`。

## 11. 阶段 3 实机验证清单（按风险从低到高）

1. 连接识别：枚举 04F3:0276/0277，确认 FF00 类 vendor collections
2. 只读探测：`receiveFeatureReport(5)` 健康检查 + reportId4 状态订阅（电量/回报率/sensorType）
3. 回报率写入（cmd=4，可逆）→ 读回确认
4. LOD / 电源 / Sensor 高阶写入（可逆）
5. DPI 写入（cmd=2，可逆）→ 读回 currentLevel 对照
6. 灯光写入（cmd=6，可逆）
7. 按键映射写入（cmd=1，注意先读回当前配置做基线，避免覆盖用户板载配置）
8. 宏下发（cmd=17 擦除 + cmd=16 分块）——先在单一非关键按钮（如侧键）上验证

## 12. 风险与未决项

1. **多媒体 128 类第二/三字节拆分规则**：前端只提供查表值，拆分算法未显式出现——实机验证时用 2-3 个键对照确认
2. **双包模式（>9键）**：FLX3 只有 6 键永远单包，双包逻辑按前端代码移植但无法实机验证
3. **BT 模式 PID**：前端只过滤 VID，BT 下 PID 未知，枚举时按 VID+产品名兜底
4. **macOS hidapi 对 reportId 模型的兼容性**：send_feature_report 需要 report ID 在首字节——阶段 1 传输层需支持「带 Report ID」模式（键盘是无 ID 模式），这是传输层抽象的第二个接口差异点
5. 前端在 2.4G 模式下某些命令时序可能不同（未发现差异分支，假设一致）
