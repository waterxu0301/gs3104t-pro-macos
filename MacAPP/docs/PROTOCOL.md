# GS3104T-PRO HID 命令协议（DeviceDriver.exe 逆向提取）

> 素材：`driver_app/app/DeviceDriver.exe`（PE32 MFC，imagebase `0x400000`）
> 方法：python3 + capstone，逐调用点回溯函数序言、线性符号执行栈缓冲区写入
> 关联笔记：`docs/RE_NOTES.md`（本文是其扩展，不修改该文件）
>
> 标注约定：
> - **[实测]** 反汇编直接确认
> - **[推断]** 由调用点/字符串/字段来源推断，未在真机验证
> - 未解项集中在第 8 节

---

## 1. 传输层总览

程序与键盘之间存在 **3 条物理/逻辑通道**（都落在同一套 HID 句柄上）：

| # | 通道 | 底层 API | 封装函数 | 用途 |
|---|---|---|---|---|
| C1 | 65 字节 Feature | `HidD_SetFeature(h, buf, 0x41)` + `DeviceIoControl(h, 0xB0192, …)` | `0x4512e0` / `0x451380` | **写命令 / 大块上传 / 9×64 读** |
| C2 | 33 字节 Output/Input 报告 | `WriteFile(h, buf, 0x21)` + `ReadFile(...)` | `0x4510c0` / `0x4511a0` | **单命令 + 回显校验 + 取回数据** |
| C3 | 4097 字节 Output 报告 | `WriteFile(h, buf, 0x1001)` + `ReadFile(h, buf, 0x1001, 300)` | 同上 | **4 KB 大数据块** |

> `0x450990` 解析 hid.dll：`HidD_SetFeature` 存 `0x5950a0`、`HidD_GetFeature` 存 `0x59509c`、
> `HidD_GetSerialNumberString` 存 `0x595098`（**本程序从不调用**）、`HidP_GetCaps` 存 `0x5950ac`。
> IOCTL `0xB0192` = `CTL_CODE(0x0B, 100, METHOD_IN_DIRECT, FILE_ANY_ACCESS)`。

### 1.1 发送函数 A — `0x44ed70`（thiscall，`ret 0xc`）

参数：`[ebp+8]=buf`、`[ebp+0xc]=len`、`[ebp+0x10]=flag`(byte)

```asm
0044edc6  mov  edi, dword ptr [ebp + 0xc]      ; len
0044edcd  push dword ptr [ebx + 0x30]           ; Sleep(cmd_delaytime, config.xml=35ms)
0044edd0  cmp  edi, 0x41
0044edd3  ja   0x44ee75                         ; len>0x41 → 分片路径
0044eddf  push 0x41
0044ede1  lea  eax, [ebp - 0x48]                ; report[0x41]
0044ede4  push 0
0044ede6  push eax
0044ede7  call 0x54da70                         ; memset(report,0,0x41)
0044edec  mov  edi, dword ptr [ebp + 8]         ; src = buf
        … movups xmm0,[edi] → [ebp-0x47] …     ; report[1..0x40] = buf[0..0x3f]
0044ee16  call 0x4512e0                         ; HidD_SetFeature(h, report, 0x41)
0044ee1e  test eax, eax
0044ee20  jle  0x44ef34                         ; 失败 → return 0
0044ee26  cmp  byte ptr [ebp + 0x10], 0         ; flag
0044ee2a  je   0x44ee6e                         ; flag==0 → return 1（不读回）
0044ee2c  push dword ptr [ebx + 0x30]
0044ee2f  call dword ptr [0x5560a8]             ; Sleep
        … 再次把 buf 复制进 report …
0044ee5c  call 0x451380                         ; DeviceIoControl(0xB0192) 读回，覆盖 report
0044ee64  cmp  byte ptr [ebp - 0x44], 1         ; report[4] == 1 ?
0044ee68  jne  0x44ef34                         ; 否 → return 0
0044ee6e  mov  al, 1                            ; 成功 → return 1
```

- **分片路径**（`len>0x41`，`0x44ee75`）：`chunks = len>>6`，每片 `report[1..0x40]=buf[i*0x40 .. +0x3F]` →
  `SetFeature` → `Sleep(this+0x30)`，失败重试最多 10 次（`cmp esi,0xa`），片间 `add edi,0x40`。
  **不检查 ACK**，返回 `[ebp-0x49]`（进入分片路径时被置 1）。
- **ACK 语义 [实测]**：`flag≠0` 时读回 65 字节，要求 `report[4]==1`，
  即 **应答 payload 的第 3 字节（`report[4]` = 应答 `buf[3]`）== 0x01 才算成功**。

### 1.2 发送函数 B — `0x44ef60`（thiscall，`ret 0xc`）

与 A 同构，差异：

- 固定 `Sleep(5)`（`push 5; call [0x5560a8]`），不用 `this+0x30`。
- flag≠0 时读回后：
  ```asm
  0044f04b  cmp  byte ptr [ebp - 0x44], 0xff   ; report[4]==0xFF → 设备“忙/NAK”
  0044f04f  jne  0x44f0b7
          … 重新 SetFeature + 再读一次 …
  0044f0b7  cmp  byte ptr [ebp - 0x44], 1       ; 最终仍要求 ==1
  ```
  → **`0xFF` = NAK/重试，`0x01` = ACK**。
- `len>0x41` 的分片路径用 `GetTickCount` 计时：每片后 `Sleep(2)`，整批耗时 `>0x64`(100ms) 即失败。

### 1.3 读函数 R64 — `0x44f240`（thiscall，`ret 8`）

参数：`[ebp+8]=buf`、`[ebp+0xc]=len`（调用点传 3 或 9，即“每键字节数”）

流程：
1. `Sleep(1); Sleep(3)`；`report[0x41]` 清零 → `report[1..]=buf[0..0x3f]` → `SetFeature`
2. `Sleep(5)` → `DeviceIoControl(GET, report, len)`，失败则重试（最多 10 次，每次 `Sleep(5)`，用 `len=0x41`）
3. `cmp byte [ebp-0x44],1` → 要求 ACK
4. **循环 9 次**：`Sleep(3)` → `DeviceIoControl(GET, report2, 0x41)` →
   `GetTickCount64` 差值必须 `≤0x168`(360ms) → `report2[1..0x40]` 拷到 `buf[esi..]`，`esi+=0x40`，且必须返回 `0x40`
5. 返回 `[ebp-0x8d]`（成功=1）

→ **一次 `04 F5` 请求可取回 9×64 = 576 (0x240) 字节**。

### 1.4 单命令函数 R32 — `0x44f490`（thiscall，`ret 0xc`）

参数：`[ebp+8]=buf`、`[ebp+0xc]=len`（多数传 `0x41`，个别 `0x21`）、`[ebp+0x10]` **未被读取**（调用点常塞一个残留值）。

```asm
0044f4ec  mov  edi, dword ptr [ebp + 0xc]      ; len
        ; 1) 校验和：Σ buf[0..len-1]（此时 buf[0x20]==0，buf[33..64]==0）
0044f50b  mov  byte ptr [esi + 0x20], dl        ; buf[0x20] = sum & 0xFF
        ; 2) buf[0..0x40] → report[ebp-0x48]（33 字节 = report id + 32 payload）
0044f53a  call 0x4510c0                         ; WriteFile(h, report, 0x21)  [失败 Sleep(10) 重试 1 次]
0044f58b  push 5 … call Sleep
        ; 3) 最多 20 次：ReadFile 取回应答（edx=report, len=0x21, timeout=5）
0044f5c5  movzx eax, byte ptr [esi + 1]
0044f5cc  cmp  al, byte ptr [ebp - 0x48]        ; resp[0] == req[1] ?
0044f5d1  mov  al, byte ptr [esi + 2]
0044f5d4  cmp  al, byte ptr [ebp - 0x47]        ; resp[1] == req[2] ?
0044f5d9  mov  al, byte ptr [esi + 3]
0044f5dc  cmp  al, byte ptr [ebp - 0x46]        ; resp[2] == req[3] ?
0044f5df  je   0x44f60b                         ; 全部相等 → 成功
        ; 4) 成功：resp[0..0x20] 覆盖回 buf[0..0x20]，返回 1
```

**应答帧格式 [实测，由 `0x44f5c5..0x44f5df` 与 `0x4357a0` 交叉验证]：**

| 应答偏移 | 含义 |
|---|---|
| `resp[0..2]` | 回显 `req[1..3]`（命令字回显，供校验） |
| `resp[3..]` | **设备数据**（随后 `movups` 覆盖回调用者 `buf[0..]`） |

成功后调用者看到的 `buf[0] == 命令字`（例：电量查询 `buf[0]==0x20`），
数据从 `buf[3]` 开始。

**请求帧格式：**

| 请求偏移 | 含义 |
|---|---|
| `buf[0]` | Report ID = `0x00` |
| `buf[1]` | **命令字**（0x03/0x05/0x07/0x0C/0x0F/0x1F/0x20…） |
| `buf[2]` | **后续 payload 长度 N**（0x10=16、0x04=4、0x01=1、0x1C=28…）[推断] |
| `buf[3]` | 次级参数（常为 0） |
| `buf[4 .. 4+N-1]` | payload；末尾常带 `AA 55` 终止符 |
| `buf[0x20]` | **校验和** `= (Σ buf[0..31]) & 0xFF`（计算时 `buf[0x20]` 为 0） |

### 1.5 其它封装

| 地址 | 说明 |
|---|---|
| `0x44f170` (ret 8) | `memset(report,0,0x1001); memcpy(report+1, buf, 0x1000); WriteFile(0x1001)`，成功后再 `ReadFile(0x1001, timeout 300ms)`。**仅 1 个调用点 `0x423253`** |
| `0x44f630` (ret 4) | 构造 33 字节帧：`report[1]=2`，按 6 组×6 字节算和存 `report[0x20]`；`WriteFile(0x21)` + `ReadFile`，校验 `resp[0]==2 && resp[2]==req[2] && resp[3]==req[3]`。**仅 1 个调用点 `0x44fc33`**（由 `0x44f910` 调，`0x434272` 调 `0x44f910`） |
| `0x4510c0` | `WriteFile`（按 `HidP_GetCaps.OutputReportByteLength` 先拷贝补齐） |
| `0x4511a0` | 异步 `ReadFile`（overlapped + 等待），结果拷到 `edx` |

---

## 2. 通用帧约定

1. 所有 64/65 字节命令共用一个**栈缓冲区**（典型 `ebp-0x54`，也见 `ebp-0x50` / `ebp-0x48` / `ebp-0x1014`）。
   调用前 `memset(base, 0, 0x41)`，再 `mov word [base], imm` 写 `buf[0..1]`。
2. **`AA 55` 终止符**：`mov word [ebp-X], 0x55aa`，位置 = payload 末尾 2 字节：
   - 16 字节 payload → `buf[14..15]`
   - 20 字节读帧（4 字节头 + 16 payload）→ `buf[18..19]`
   - 64 字节整包（系统配置）→ `buf[62..63]`
   - 576 字节按键映射块 → `buf[574..575]`
3. **标准写会话骨架**（几乎所有写函数都长这样）：

```
04 18  flag=1   ← 进入配置会话
04 13/17/19/20/23/28/72 … flag=1  ← 选择子功能/页，带参数
<payload> flag=0/1 ← 数据
04 02  flag=1   ← 提交/写入
04 F0  flag=0   ← 退出配置会话
```

4. **flag 含义 [实测]**：`flag=0` → 只 `SetFeature`，不读回；`flag=1` → 还要 `DeviceIoControl` 读回并校验
   `report[4]==1`。实际所有“要确认”的命令都传 1；收尾的 `04 02` 传 1，`04 F0` 传 0。

---

## 3. 命令总表

### 3.1 C1 通道 — 写命令（`0x44ed70` / `0x44ef60`）

| 命令字 | 调用点(VA) | flag | len | 所在功能函数 | 语义 |
|---|---|---|---|---|---|
| `04 18` | 0x414285, 0x41863b, 0x423096→0x423102, 0x423b58, 0x42b0f4, 0x433fd8, 0x44b7e8, 0x44b945 | 1 | 0x41 | 各写函数入口 | **进入配置会话** |
| `04 17` `buf[2]=1 buf[8]=1` | 0x4142a7 | 1 | 0x41 | 0x414230 | 会话子态 1（系统配置） |
| `04 11` / `04 27` `buf[8]=9` | 0x41866c | 1 | 0x41 | 0x4185e0 | **选按键映射层**：入参=0→`04 11`（主层），≠0→`04 27`（Fn 层）[推断] |
| `04 13` `buf[8]=1` | 0x42b112, 0x433ff6, 0x44b806 | 1 | 0x41 | 0x42b070 / 0x433fa0 / 0x44b7b0 | 选择子页 0x13 |
| `04 19` | 0x42d6e0 | 1 | 0x41 | 0x42d660 | 灯光/宏大块**会话开始** |
| `04 15` `buf[8]=N` | 0x42db5a | 1 | 0x41 | 0x42d660 | 声明后续数据块参数 |
| `04 20` `buf[8]=3\|8` | 0x428070, 0x4329d0 | ≠0 | 0x41 | 0x428000 / 0x432960 | **每键 RGB 上传声明**（每键 3 或 8 字节，`this+0x7ac≠0`→8） |
| `04 23` `buf[8]=3\|9` | 0x44b976 | 1 | 0x41 | 0x44b8c0 | **每键灯光上传声明**（3 或 9 字节，`this+0x7ac≠0`→9） |
| `04 28` `buf[8]=1` | 0x423b86 | 1 | 0x41 | 0x423b20 | RTC/日期时间子页 |
| `04 72` `buf[2]=id, buf[8..9]=count` | 0x42310d→0x42319f | 1 | 0x41 | 0x422b60 | **4 KB 大数据块上传开始** |
| `00 01` + payload + `AA55@62` | 0x414428 | **0** | 0x41 | 0x414230 | **系统配置数据**（见 4.2） |
| `80 00 00 00 … AA55@14` | 0x44b84a | **0** | 0x41 | 0x44b7b0 | 16 字节数据帧（见 4.4） |
| `<payload> AA55@14` | 0x42b17a, 0x434029 | **0** | 0x41 | 0x42b070 / 0x433fa0 | 16 字节数据帧 |
| `04 02` | 0x414452, 0x418dba, 0x423c37, 0x4282af, 0x42b00a, 0x42b1a4, 0x42dba8, 0x432b57, 0x434053, 0x44b874, 0x44bc87 | 1 | 0x41 | 全部写函数 | **提交/写入** |
| `04 F0` | 0x418e2a, 0x42b1ce, 0x43407d, 0x44b89e | **0** | 0x41 | 同上 | **退出配置会话** |
| `<…>` 数据块 | 0x418d3a | 1 | **0x240** | 0x4185e0 | 按键映射表 576 字节（9 片） |
| `<…>` 数据块 | 0x42db7a | 1 | **0x190**(400) | 0x42d660 | 400 字节数据块 |
| `<…>` 数据块 | 0x428283, 0x432b2b | ≠0 | **0x200**(512) / **0xC0**(192) | 0x428000 / 0x432960 | 每键 RGB 数据（64 键 × 8 或 × 3） |
| `<…>` 数据块 | 0x44bc0b | 1 | **0xC0**(192) | 0x44b8c0 | 每键灯光数据 |

### 3.2 C1 通道 — 读命令（`0x44f240`）

| 命令字 | 调用点 | len | 所在函数 | 语义 |
|---|---|---|---|---|
| `04 F5` `buf[8]=3\|9` | 0x42aee3 | 3 或 9 | 0x42ae50 | **取回 576 字节块**（9×64），随后解析为按键/灯光记录 |

### 3.3 C2 通道 — 命令（`0x44f490`）

| 请求 `buf[0..]` | 调用点 | 所在函数 | 语义 / 应答 |
|---|---|---|---|
| `00 07 10 00` + 16B payload(`01 alttab altf4 win fn sleep 0 resp …`+`AA55@18`) | 0x41464c | 0x4144a0 | **读系统配置**（与 `00 01` 写帧同构，前加 4 字节头） |
| `00 03 04 xx 02 00 <profile> 00` | 0x4192bb | 0x4191c0 | 按 profile 查询/下发（4 字节 payload） |
| `00 <type> <0x1C\|0x10> <index>` + 28B 记录 | 0x419156（循环 21 次） | 0x418e80 | **逐条写按键映射记录**（响应被丢弃） |
| `00 0c 10 00` + 16B(日期时间) + `AA55@18` | 0x423ce7 | 0x423c50 | 日期时间读/写（同 4.5） |
| `00 05 10 00` + 16B payload + `AA55@18` | 0x42b2d7 | 0x42b210 | 0x414… 对应 `04 13` 数据帧的读版本 |
| `00 05 10 00 80 00 00 00 …` + `AA55@18` | 0x44bdd0 | 0x44bd30 | 对应 `80 00 00 00` 数据帧的读版本 |
| `00 05 01 00 <page>` + `AA55@18` | 0x43493c | 0x4348d0 | 按 profile 页查询（`this+0x784==2` 才发） |
| `00 1f …` | 0x4345ca | 0x434200 | **状态轮询**（循环内，分支 `ebx==0xE/0x14` 再调 0x434eb0/0x435280） |
| `00 0f …` | 0x4350d1 | 0x434eb0 | **能力/待同步标志**：应答后检查 `this+0x7a4 bit2`→`Sleep(50)`+`0x42b070`，`bit8(0x100)`→`Sleep(50)`+`0x433fa0` |
| `00 20 01 00` | 0x435845 | 0x4357a0 | **读电量**（15 s 节流，见 4.7） |
| `00 <…>`（循环 21 次 / 7 次，记录 0x1C 字节，`Sleep(2)`） | 0x423941, 0x423a16, 0x42e18f, 0x44c05b, 0x44c13d | 0x423400 / 0x42dbe0 / 0x44bd30 | 逐条批量读/写 |
| `len=0x21` 的变体 | 0x432cd2 | 0x432ba0 | 与 `04 20` RGB 对应的读回（校验和按 33 字节算） |

### 3.4 C3 通道

| 调用点 | 所在函数 | 说明 |
|---|---|---|
| 0x423253 (`0x44f170`) | 0x422b60 | 一次写 4096 字节块（`report[0]=0, report[1..0x1000]=data`），随后 `ReadFile(0x1001)` |

---

## 4. 按功能分组的完整字节模板

### 4.1 会话控制（所有写流程共用）

| 字节 | 值 | 说明 |
|---|---|---|
| `buf[0..1]` | `04 18` | 进入配置（flag=1，等 ACK） |
| `buf[0..1]` | `04 02` | 提交（flag=1，等 ACK） |
| `buf[0..1]` | `04 F0` | 退出（flag=0） |

反汇编（`0x42b070` 起手，`listing/0042b070.txt`）：

```asm
0042b0cf  push 0x40
0042b0d1  lea  eax, [ebp - 0x53]
0042b0d4  push 0
0042b0d6  push eax
0042b0d7  call 0x54da70                    ; memset(buf+1,0,0x40)
0042b0df  mov  word ptr [ebp - 0x54], 0x1804
0042b0e5  lea  eax, [ebp - 0x54]
0042b0e8  push 1                            ; flag = 1
0042b0ea  push 0x41                         ; len  = 65
0042b0ec  push eax                          ; buf
0042b0ed  call 0x413440                     ; 取单例设备对象
0042b0f2  mov  ecx, eax
0042b0f4  call 0x44ed70                     ; 发送
```

### 4.2 系统配置（按键响应时间 / 休眠时间 / 禁用键）— 函数 `0x414230`(写) 与 `0x4144a0`(读)

**写帧 `00 01`（调用点 `0x414428`，flag=0，`AA55@62`）**

| buf | 字段 | 来源 |
|---|---|---|
| 0 | `0x00` | 常量 |
| 1 | `0x01` | 常量（`mov word [ebp-0x54],0x100`） |
| 2 | 禁用 Alt+Tab | `this+0x678` 对象取值 `≠0 → 1`（键名 `disable_alttab`，见 `0x413910`） |
| 3 | 禁用 Alt+F4 | `this+0x67c` → `disable_altf4` |
| 4 | 禁用 Win 键 | `this+0x680` → `disable_win` |
| 5 | `fn_switch` | config 键 `0x56d428` "fn_switch" → int |
| 6 | `sleep_time` | config 键 `0x56d39c` "sleep_time" → int |
| 7 | （0，保留） | — |
| 8 | `key_respondtime`（按键响应时间 5 档） | config 键 `0x56d37c` "key_respondtime" → int |
| 62..63 | `AA 55` | `0x414416  mov word [ebp-0x16],0x55aa` |

发送序列：`04 18`(f=1) → `04 17`,`buf[2]=1`,`buf[8]=1`(f=1) → `00 01`+payload(f=0) → `04 02`(f=1)

**读帧 `00 07 10 00`（调用点 `0x41464c`，C2 通道）**

| buf | 字段 |
|---|---|
| 0..1 | `00 07`（命令） |
| 2 | `0x10` = payload 长度 16 [推断] |
| 3 | `0x00` |
| 4..19 | 与写帧完全同构（`01 | alttab | altf4 | win | fn | sleep | 0 | resp | … | AA55`），即写 payload 整体右移 4 字节，`AA55` 落在 18..19 |

> 应答覆盖回 `buf` 后由上层重新入库；本函数本身不解析（`0x41464c` 后直接析构返回）。

### 4.3 按键映射（key remap，主层 + Fn 层）— 函数 `0x4185e0`(写) / `0x418e80`、`0x4191c0`(读)

**写流程（`0x4185e0`，入参 `[ebp+8]`）**

1. `04 18` (f=1)
2. `04 <al>`：`al = ([ebp+8]!=0) ? 0x27 : 0x11`，`buf[8]=9`，f=1 —— **层选择：0x11=主层，0x27=Fn 层 [推断]**
3. 组装 **576 (0x240) 字节记录表** → `send A(len=0x240, flag=1)`（内部切成 9 片 × 64 字节 SetFeature）
   - 每条记录 **4 字节**：`[type][arg0][arg1][arg2]`，按 `mov [ebp+idx*4-0x360], …` 写入
   - 表尾 `buf[574..575] = AA 55`（`0x418cc4 mov word [ebp-0x122],0x55aa`）
   - 记录 type 由 DB 字段 `[edi+0x18]`（键功能类型）决定，映射表 [推断]：

| `[entry+0x18]` | 记录 | 含义（依据常量） |
|---|---|---|
| 1 | `05 03 …` | 禁用/特殊 |
| 2 | `02 <code1> <code2=call 0x451b40(key)>` | **默认按键**（`0xE0..0xE7` 修饰键会额外补一条记录） |
| 3 | `06 <macroIdx> <v> <v>` | **宏**（在宏列表中查找 `[edi+0x1c]` 得到索引 cl） |
| 4 | （跳过，不产生记录） | — |
| 5 | `01 <lo> <hi>`：`1→01 01, 2→01 04, 3→01 02, 4→01 03, 5→03 01, 6→03 FF, 7→01 08, 8→01 10` | **Win 快捷方式** |
| 6 | `03 <code>`：`1→CD, 2→B7, 3→B6, 4→B5, 5→E9, 6→EA, 7→E2` | **多媒体**（HID Consumer：Play/Pause, Stop, Prev, Vol+, Vol-, Mute…） |
| 7 | `02 <lo> <hi>`：`1→08 07, 2→08 08, 3→08 0F, 4→01 1A, 5→04 2B, 6→01 06, 7→01 19, 8→01 1B, 0xB→(type=02 01), 8..0xC→(type=05 02)+[edi+0x1c]` | 打开程序/网站/发送文字/多键等 |
| 0xD | `07 <a> <b> <c>` | 鼠标/其它 |
4. `04 02` (f=1)
5. `04 F0` (f=0)

**读/回写（`0x418e80`，循环 21 次，C2 通道）**

```asm
004190a6  push 0x41 / lea eax,[ebp-0x54] / push 0 / push eax / call memset
004190bf  mov  byte ptr [ebp - 0x53], al      ; buf[1] = 记录类型
004190c5  mov  al, 0x1c                        ; 28
004190c7  mov  byte ptr [ebp - 0x51], bl       ; buf[3] = 索引 (0..0x14)
004190d2  cmove eax, ecx                       ; 索引==0x14 时长度改 0x10(16)
004190db  mov  byte ptr [ebp - 0x52], al       ; buf[2] = 记录长度 0x1C/0x10
004190e1  movups [ebp-0x50], xmm0              ; buf[4..19]  = record[0..15]
004190f2  movq  [ebp-0x40], xmm0               ; buf[20..27] = record[16..23]
004190e5  mov  dword ptr [ebp - 0x38], eax     ; buf[28..31] = record[24..27]
00419156  call 0x44f490                        ; 发送（响应未解析）
0041915b  push 2 / add esi,0x1c / call Sleep(2) / inc ebx / cmp ebx,0x15 / jl 0x4190a6
```

`0x4191c0`（profile 相关查询，`ret 4`）：`00 03 04 <prof> 02 00 <profile> 00`，
`buf[1] = ([ebp+8]!=0) ? 0x0D : 0x03`，`buf[6] = this+0x800`（profile 号）。

### 4.4 宏 / 特殊键数据帧 — 函数 `0x42b070`(写) / `0x42b210`(读)，`0x433fa0`、`0x44b7b0`

**写序列（`0x42b070`）**：`04 18` → `04 13`,`buf[8]=1` → 数据帧 → `04 02` → `04 F0`

数据帧（flag=0，`AA55@14`，16 字节 payload）：

| buf | 字段 | 来源 |
|---|---|---|
| 0 | 子命令/模式 | `this+0x804`（byte） |
| 1..3 | 24 位值（小端） | 局部记录 `+0x24`（`[ebp-0x64]`） |
| 8 | 记录 `+0x1C` | `[ebp-0x6c]` |
| 9 | 记录 `+0x10` | `[ebp-0x78]` |
| 10 | 记录 `+0x14` | `[ebp-0x74]` |
| 11 | 记录 `+0x18` | `[ebp-0x70]` |
| 14..15 | `AA 55` | `0x42b16a mov word [ebp-0x46],0x55aa` |

**读帧（`0x42b2d7`）**：`00 05 10 00` + 上述 16 字节 payload（右移 4 字节，`AA55@18`）。

**`0x433fa0` / `0x44b7b0` 的变体**（`buf[0]` 直接是子命令）：

- `0x434029`：`buf[0] = this+0x808`，`AA55@14`
- `0x44b84a`：`80 00 00 00 | buf[8]=0 | buf[9]=<this+0x814 相关> | 00 00 | AA55@14`
  - `0x44b821 mov byte [ebp-0x40],al` → `buf[8]`，`0x44b827 mov dword [ebp-0x48],0x80` → `buf[0..3]=80 00 00 00`

对应读帧 `00 05 10 00 80 00 00 00 …`（`0x44bdd0`）。

### 4.5 日期时间（RTC）— 函数 `0x423b20`(写) / `0x423c50`(读)

**写序列**：`04 18` → `04 28`,`buf[8]=1` → `00 <n>`+日期时间 → `04 02`

数据帧（`0x423c0d`，flag=1，`AA55@62`，buf[0]=0）：

| buf | 字段 | 来源 |
|---|---|---|
| 1 | `al+1` | `call [0x55685c](this+0x6b0)` 结果 +1 |
| 2 | `0x5A` | 常量 |
| 3 | `year % 0x7D0`（低字节，即 year-2000） | `GetLocalTime` → `div 0x7d0` 余数 `dl` |
| 4 | 月 | `SYSTEMTIME.wMonth` |
| 5 | 星期 | `wDayOfWeek` |
| 6 | 时 | `wHour` |
| 7 | 分 | `wMinute` |
| 8 | 秒 | `wSecond` |
| 10 | 日 | `wDay` |
| 62..63 | `AA 55` | `0x423c00 mov word [ebp-0x12],0x55aa` |

`GetLocalTime` 调用：`0x423b8b lea eax,[ebp-0x60]; call [0x5560b0]`。

**读帧 `00 0c 10 00`**（`0x423ce7`）：同 payload 右移 4，`AA55@18`。

### 4.6 RGB 灯光

#### 4.6.1 每键 RGB — 函数 `0x428000` / `0x432960`（命令 `04 20`，`send B`）

```asm
00428043  cmp  dword ptr [ebx + 0x7ac], 0
0042804a  mov  ecx, 8
0042804f  mov  eax, 3
00428054  mov  word ptr [ebp - 0x54], 0x2004
0042805a  cmovne eax, ecx            ; buf[8] = (this+0x7ac!=0) ? 8 : 3   ← 每键字节数
00428060  mov  byte ptr [ebp - 0x4c], al
        … send B(flag=≠0, len=0x41)
00428254  push ecx
00428255  cmp  dword ptr [eax + 0x7ac], 0
0042825c  lea  eax, [ebp - 0x2ac]
00428262  je   0x428276
00428264  push 0x200                 ; 512 = 64 键 × 8
00428269  jmp  0x42827b
00428276  push 0xc0                  ; 192 = 64 键 × 3
0042827b  push eax                   ; 600 字节局部缓冲 ebp-0x2ac
0042827c  call 0x413440
00428283  call 0x44ef60              ; 分片上传
        … 若成功 → 04 02 (send B, flag=0x41…)
```

- 数据源：`0x428000` 用 `this+0x4e8`，`0x432960` 用 `this+0x60c`（两条不同的灯光向量 → **主灯 vs 自定义/用户灯** [推断]）
- 收尾：`04 02`（`0x42829c`，send B，`0x4282af`）
- 对应读回：`0x432ba0`（`0x432cd2`，`len=0x21`）

#### 4.6.2 每键灯光（RGB/单色两种模式）— 函数 `0x44b8c0`（命令 `04 23`）

```asm
0044b94a  cmp  dword ptr [ebx + 0x7ac], 0
0044b951  mov  ecx, 9
0044b956  mov  eax, 3
0044b95b  mov  word ptr [ebp - 0x54], 0x2304
0044b961  cmovne eax, ecx             ; buf[8] = 9（RGB）或 3（单色）
0044b966  mov  byte ptr [ebp - 0x4c], al
        … send A(0x41, flag=1)
        … 600 字节缓冲 → send A(len=0xC0=192, flag=1)   @0x44bc0b
        … 04 02 @0x44bc87, 04 F0 @0x44bcf3
```

分发入口 `0x434950`：
```asm
00434950  mov  eax, dword ptr [ecx + 0x784]   ; 连接模式
00434956  test eax, eax
00434958  je   0x44b8c0                       ; 0  → 有线
0043495e  cmp  eax, 2
00434961  je   0x44bd30                       ; 2  → 2.4G 无线
```
→ **同一功能按连接模式分派到 `0x44b8c0`(写) / `0x44bd30`(读)**。

#### 4.6.3 灯光模式/效果大块 — 函数 `0x42d660`(写) / `0x42dbe0`(读)

序列：
1. `04 19`（f=1）@0x42d6e0 —— 会话开始
2. 组装 3584 (0xE00) 字节缓冲（`push 0xe00; lea eax,[ebp-0xe54]; memset`），`edi=0x190`(400)
3. `04 15` `buf[8]=al`（f=1）@0x42db5a —— `al` 来自数据（模式索引）
4. `Sleep(30)` → **`send A(len=0x190=400, flag=1)`** @0x42db7a（400 字节数据块）
5. `Sleep(30)` → `04 02`（f=1）@0x42dba8

读对应 `0x42dbe0` → `0x42e18f`（循环，记录 0x1C 字节，`Sleep(2)`）。

### 4.7 电量轮询 — 函数 `0x4357a0`

```asm
004357b3  cmp  dword ptr [esi + 0x784], 2      ; 仅 2.4G 无线
004357ba  jne  0x43588f
0043580c  call GetTickCount
0043580e  sub  eax, dword ptr [0x5951c4]
00435814  cmp  eax, 0x3a98                      ; 15000 ms 节流
00435819  jb   0x43588e
00435832  mov  word ptr [ebp - 0x47], 0x120     ; buf[1]=0x20, buf[2]=0x01
00435845  call 0x44f490                         ; 请求 00 20 01 00
0043584a  test al, al
0043584c  je   0x43588e                         ; 发送失败
0043584e  cmp  byte ptr [ebp - 0x48], 0x20      ; resp[0]==命令字 0x20
00435852  jne  0x43588e
00435854  mov  al, byte ptr [ebp - 0x45]        ; resp[3] = 电量百分比
00435857  test al, al
00435859  je   0x43588e
0043585b  movzx eax, al
0043585e  mov  ecx, 0x64
00435863  cmp  eax, ecx
00435867  cmova eax, ecx                        ; 钳到 100
0043586a  mov  ecx, dword ptr [esi + 0x304]
00435871  call dword ptr [0x55682c]             ; UI 更新电量
```

→ **读电量命令：`00 20 01 00`，应答 `resp[0]=0x20`（回显），`resp[3]=battery%`。**
这是**唯一一处真正解析 C2 通道应答数据**的地方，验证了 §1.4 的应答格式。

### 4.8 4 KB 大数据块 — 函数 `0x422b60`(写) / `0x423400`(读)

```asm
0042306f  push 0x1000 / lea eax,[ebp-0x1013] / push 0 / push eax / call memset
00423096  mov  word ptr [ebp - 0x1014], 0x1804        ; 04 18
00423102  call 0x44ed70                                ; (flag=1, len=0x41)
0042310d  mov  word ptr [ebp - 0x1014], 0x7204        ; 04 72
00423116  mov  al, byte ptr [esi + 0x52c1c]
0042311c  mov  byte ptr [ebp - 0x1012], al            ; buf[2] = 数据 id
00423128  mov  byte ptr [ebp - 0x100c], al            ; buf[8] = count 低字节
00423131  mov  byte ptr [ebp - 0x100b], al            ; buf[9] = count 高字节
0042319f  call 0x44ed70                                ; (flag=1, len=0x41)
        ; 循环 count 次：
        ;   memset(buf,0,0x1001); memcpy(buf, src, 0x1000)
00423253  call 0x44f170                                ; WriteFile(0x1001) + ReadFile
        ; 进度条 "Loading: %d%%"
004232ff  mov  word ptr [ebp - 0x1014], 0x204         ; 04 02
0042336b  call 0x44ed70
```

- 命令：`04 72 <id> <00> <00> <00> <00> <00> <count:u16> …`
- 之后是 `count` 个 **4096 字节裸块**（C3 通道，`report[0]=0`，无命令头）
- 该函数带 `"Loading: %d%%"` 与 `"%sled\%s\%s\"` 字符串 → **大容量灯效/宏资源上传** [推断]
- 读对应 `0x423400`（`0x423941`/`0x423a16`，记录 0x1C 字节，进度同 `"Loading: %d%%"`）

### 4.9 状态/能力轮询

- **`00 1f`**（`0x4345ca`，在 `0x434200` 的主循环里）：应答后按 `ebx` 分派
  `ebx==0xE → 0x434eb0`（整包加载）、`ebx==0x14 → 0x435280`。
- **`00 0f`**（`0x4350d1`，`0x434eb0` 末尾）：读能力标志
  `this+0x7a4 bit2` → `Sleep(50)` + `0x42b070`；`bit8(0x100)` → `Sleep(50)` + `0x433fa0`。

### 4.10 `04 F5` 大块读（函数 `0x42ae50`）

```asm
0042aeb1  mov  edx, 3
0042aeb6  mov  word ptr [ebp - 0x2ac], 0xf504        ; 04 F5
0042aebf  test ecx, ecx                               ; ecx = this+0x7ac
0042aec3  mov  esi, 9
0042aec8  cmovne eax, esi                             ; buf[8] = 9 或 3
0042aecb  cmovne edx, esi                             ; len    = 9 或 3
0042aece  mov  byte ptr [ebp - 0x2a4], al
0042aeda  push edx / push eax / call 0x413440
0042aee3  call 0x44f240                               ; 读回 9×64 = 576 字节
0042aee8  test al, al
0042aeea  je   0x42b03b                               ; 失败
        … 解析 576 字节为记录（`call [0x556ad0]` 取容器）
0042b00a  call 0x44ed70                               ; 04 02 (flag=1)
```

---

## 5. 写函数 / 读函数配对总表

| 功能 | 写函数（C1） | 读/回写函数（C2/C1） |
|---|---|---|
| 系统配置（fn_switch/sleep/key_respondtime/禁用键） | `0x414230` | `0x4144a0`（`00 07 10 00`） |
| 按键映射 主层/Fn 层 | `0x4185e0`（`04 11`/`04 27` + 576B） | `0x418e80`（21×28B）、`0x4191c0`（`00 03`） |
| 宏/特殊键数据 | `0x42b070`（`04 13`）、`0x433fa0`、`0x44b7b0` | `0x42b210`、`0x4348d0`、`0x44bd30` |
| 每键 RGB | `0x428000`（`04 20`, `this+0x4e8`） | `0x432ba0` |
| 每键 RGB（第二组） | `0x432960`（`04 20`, `this+0x60c`） | （同上） |
| 每键灯光 RGB/单色 | `0x44b8c0`（`04 23`） | `0x44bd30`（`00 05 10 00 80…`） |
| 灯光模式/效果块 | `0x42d660`（`04 19`/`04 15` + 400B） | `0x42dbe0` |
| 日期时间 RTC | `0x423b20`（`04 28`） | `0x423c50`（`00 0c 10 00`） |
| 4 KB 大数据 | `0x422b60`（`04 72` + C3） | `0x423400` |
| 大块读 | `0x42ae50`（`04 F5` → 576B） | — |
| 电量 | — | `0x4357a0`（`00 20 01`） |
| 整包应用 | `0x434200`（内部调用上列全部 + `04 1f` 轮询） | `0x434eb0`（`00 0f` + 依次写回） |

**`0x434200`（Apply/写全量）调用序列**（节选）：
`0x44f910(C32) → 0x4357a0(电量) → 0x434720 → 0x42d660 → 0x42dbe0 → 0x42b070 → 0x42b210 → 0x4348d0 → 0x414230 → 0x4144a0 → 0x422b60 → 0x423400 → 0x44f490(00 1f) → 0x434eb0 → 0x42ae50 → 0x428000 → 0x4332f0 → 0x4357a0`

**`0x434eb0`（Load/读全量）序列**：
`0x42d660 → 0x4185e0 → 0x4185e0 → 0x44b8c0 → 0x44bd30 → 0x42b070 → 0x433fa0 → 0x414230 → 00 0f → 0x42b070 → 0x433fa0`

**`0x434720`（per-profile 应用）序列**：
`0x423b20 → 0x423c50 → 0x4185e0 ×2 → 0x418e80 ×2 → 0x4185e0 ×2 → 0x4191c0 ×2`

---

## 6. 读取键盘当前配置的方法（按实测顺序）

1. **整包读**：`0x434eb0` 路径 —— 先发 `00 0f` 取能力标志，再按标志依次执行
   `00 05 10 00 …`（宏/特殊键）、`00 07 10 00 …`（系统配置）、`00 0c 10 00 …`（日期时间）等 C2 命令；
   每条应答把设备数据放进 `buf[3..]`。
2. **按键映射**：`0x418e80` 循环 21 条 `00 <type> <len> <index>` + 记录；或 `0x42ae50` 发 `04 F5`
   一次取回 576 字节再本地解析。
3. **每键 RGB**：`0x432ba0`（`0x432cd2`，`len=0x21`）。
4. **电量**：`00 20 01 00` → `buf[3]`。
5. **固件版本 / 序列号**：**本程序不通过 HID 命令读取**——`HidD_GetSerialNumberString`
   虽在 `0x450990` 中被解析（存 `0x595098`）但**全程序无调用点**；
   `HidD_GetAttributes`/`HidD_GetProductString` 仅在设备枚举 `0x450aa0` 中使用
   （VID/PID/产品名）。固件升级走独立的 Sonix ISP 工具（`FirmwareUpdateTool.exe`），不在本协议内。

---

## 7. 关键反汇编片段索引

| 片段 | 地址 | 说明 |
|---|---|---|
| 发送 A 主体 | `0x44ed70-0x44ef54` | SetFeature + 可选 GET + ACK 判定 |
| 发送 B 主体 | `0x44ef60-0x44f168` | 同上，`0xFF` NAK 重试，100ms 计时 |
| 9×64 读 | `0x44f240-0x44f48c` | ACK + 9 次 DeviceIoControl |
| C2 单命令 | `0x44f490-0x44f622` | 校验和 + WriteFile + 回显校验 + 应答回拷 |
| 4 KB 块 | `0x44f170-0x44f22f` | WriteFile(0x1001) |
| 36 字节帧 | `0x44f630-0x44f7f4` | `report[1]=2` + 6×6 校验和 |
| 系统配置写 | `0x414230-0x414494` | `04 18/04 17/00 01/04 02` |
| 系统配置读 | `0x4144a0-0x41468e` | `00 07 10 00` |
| 按键映射写 | `0x4185e0-0x418e80` | 4 字节记录编码 + 576B 上传 |
| 按键映射逐条 | `0x4190a6-0x419166` | 28 字节记录帧 |
| 电量 | `0x4357a0-0x43589d` | `00 20 01` + `resp[3]` 解析 |
| 每键 RGB | `0x428000-0x4282f0` | `04 20` + 512/192 字节分片 |
| 每键灯光 | `0x44b8c0-0x44bd30` | `04 23` + 192 字节 |
| RTC | `0x423b20-0x423c4a` | `04 28` + `GetLocalTime` |

---

## 8. 未解 / 待验证

1. **`04 72` + 4 KB 块的具体数据类型**：`0x422b60` 只有 `"Loading: %d%%"`、`"%sled\%s\%s\"`
   与 `this+0x52c1c` 等深层偏移，未与 SQLite 表（`t_macro_data`/`t_customlight_data`…）直接挂钩。
   需真机抓包或继续追 `edi` 数据源。
2. **`04 19`/`04 15` 的 400 字节块**：疑似灯光模式/实时灯效参数，但未逐字节拆出字段。
3. **`04 11` vs `04 27`**：由入参 `[ebp+8]` 是否为 0 决定，配合 `0x418e80` 的 21 条记录，
   高度疑似主层/Fn 层，但未在 UI 层找到直接证据。
4. **C1 通道 ACK 的 `report[4]==1`** 与 **C2 通道 `resp[0..2]` 回显** 是两套独立的应答格式，
   未找到把二者统一的帧定义（可能对应 HID 描述符里 64 字节与 32 字节两个 collection）。
5. **`0x44f240` 首次 `DeviceIoControl` 返回 `>=0` 会直接返回失败**（`0x44f334 jns 0x44f44e`），
   只有返回负值才进入重试循环——按字面读是“首次读必须失败”，
   更可能是该 IOCTL 首次以 `len=3/9` 读时必然失败（长度不匹配），需真机确认。
6. **profile 切换命令**：`0x43493c` 的 `00 05 01 00 <page>` 与 `0x4192bb` 的 `00 03 04 <prof>`
   都带 profile 索引，但没有找到独立的“切换 profile”短命令；切换疑似通过
   `this+0x784`/`this+0x800` 状态 + 整包重发实现。
7. **恢复出厂 / 重置**：`0x414230` 中的 `04 17 (buf[2]=1, buf[8]=1)` 与 `00 01` 组合尚未确认
   是否即“恢复出厂”；语言文件里有对应文案但未反查到 UI 事件 → 命令映射。

---

## 9. 附：调用点全清单

- `0x44ed70`（41 个）：`0x414285 0x4142a7 0x414428 0x414452 0x41863b 0x41866c 0x418d3a 0x418dba 0x418e2a 0x423102 0x42319f 0x42336b 0x423b58 0x423b86 0x423c0d 0x423c37 0x42b00a 0x42b0f4 0x42b112 0x42b17a 0x42b1a4 0x42b1ce 0x42d6e0 0x42db5a 0x42db7a 0x42dba8 0x433fd8 0x433ff6 0x434029 0x434053 0x43407d 0x44b7e8 0x44b806 0x44b84a 0x44b874 0x44b89e 0x44b945 0x44b976 0x44bc0b 0x44bc87 0x44bcf3`
- `0x44ef60`（6 个）：`0x428070 0x428283 0x4282af 0x4329d0 0x432b2b 0x432b57`
- `0x44f490`（16 个）：`0x41464c 0x419156 0x4192bb 0x423941 0x423a16 0x423ce7 0x42b2d7 0x42e18f 0x432cd2 0x4345ca 0x43493c 0x4350d1 0x435845 0x44bdd0 0x44c05b 0x44c13d`
- `0x44f240`（1 个）：`0x42aee3`
- `0x44f170`（1 个）：`0x423253`
- `0x44f630`（1 个）：`0x44fc33`
