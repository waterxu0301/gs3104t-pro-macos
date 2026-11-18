# 项目进展复盘（截至 2025-11-18）

## 一、项目愿景与总目标

把 GANSS 键鼠从「官方云端网页驱动（仅限 DSMW 批次 + 需要 Chrome WebHID 授权）」中解放出来，
做成一个 **本地化、插件化、跨平台的开源键鼠驱动框架**：

```
数据流: 浏览器 UI (127.0.0.1:8340)
        ↓ JSON API
   Python 后端 (framework/ 插件化)
        ↓ 传输层抽象 (hidapi / IOHIDManager seize / WebHID 桥)
   HID 设备 (键盘 05AC:024F / 鼠标 04F3:026F)
```

## 二、已完成并实机验证 ✅

### 2.1 框架层（阶段 1）
| 交付物 | 状态 |
|---|---|
| `framework/transport.py` — `import hid` 统一传输层，显式 report_id，poll_input | ✅ 键盘实机验证 |
| `framework/base_driver.py` — BaseDeviceDriver 抽象基类 | ✅ |
| `framework/plugin_manager.py` — manifest 多条件 AND 匹配、插件启停/删除、设备枚举路由 | ✅ |
| `framework/safety.py` — 双模式 SafetyGuard（HARDWARE_READBACK / SHADOW_STATE_ACK）+ 原子 shadow | ✅ |
| `framework/api.py + server.py` — API v2（plugins.* / devices.scan / device.* / profiles.*） | ✅ HTTP 全链路回归 |
| 插件管理前端（启停/列表） | ✅ |

### 2.2 键盘插件（ganss_gs3104t_pro）—— **功能最完整，全部实机验证**
| 能力 | 协议 | 实机 |
|---|---|---|
| 19 种灯效 + 颜色/亮度/速度 | 旧协议 33B 短报文 | ✅ 多次 ACK |
| 单键映射 Q→W | `03`/`0D` + key_index + 4B 记录 | ✅ ACK |
| **组合键**（LCtrl+C 等 8 修饰键 bitmask） | `[2, mask, usage, 0]` | ✅ ACK |
| **媒体键**（16 种 Consumer Page 16-bit LE） | `[3, usage_lo, usage_hi, 0]` | ✅ ACK（本阶段解耦成果） |
| **禁用键** | `[1,0,0,0]` | ✅ ACK |
| **宏绑定记录** | `[6, slot, 0, 0]` | ✅ ACK |
| 112 键可视化画布（rect 坐标 SVG） | keymap.json 数据驱动 | ✅ UI |
| 普通/Fn 层切换、防自锁保护（Fn 保留） | UI 层 | ✅ |
| Profiles 多配置 + JSON 导入导出 | shadow 持久化 | ✅ |
| 蓝牙模式只读识别 + 友好提示 | IORegistry 描述符确认 | ✅ |

### 2.3 协议逆向成果（知识资产）
| 资产 | 内容 |
|---|---|
| `analysis/FLX3_逆向报告.md` | 88 条 Ge 命令、按键/宏/DPI 传感器换算/回报率/LOD/电源/灯光/出厂恢复 完整报文格式 |
| `analysis/键盘网页驱动协议逆向报告.md` | AA 头 32B 分块协议、Consumer LE 媒体键、宏指针表+事件块、键位回读通道、SET_KEYBOARD_CUSTOM_FUNCTION_ON/OFF |
| `analysis/ganss_webhid_hook.js` | WebHID 全量报文拦截脚本（实战验证可用） |
| `analysis/flx3/`, `analysis/ganss_web/` | 官方 JS 素材存档（证据链） |

### 2.4 FLX3 鼠标插件（ganss_flx3）—— 部分实机验证
| 能力 | 状态 |
|---|---|
| manifest 多条件匹配（真实 PID 0x026F）+ Elan 触摸板防误伤 | ✅ 枚举命中 |
| protocol.py 全命令编码器（38 项黄金测试 PASS） | ✅ 单元级 |
| 灯光控制 | ✅ **实机 ACK status=1** |
| IOHIDManager seize 通道（绕 macOS 鼠标接口独占） | ✅ 通道打通 |
| **WebHID 调试台**（官方同款传输层） | ✅ **连接成功 + r4 遥测解码**：电量 90%、PAW3395、回报率档位 |
| 回报率/LOD/DPI/按键/宏 命令 | ⚠️ seize 通道 status=0（重放官方报文也 0）→ WebHID 通道待验证 |

### 2.5 多设备同屏
| 能力 | 状态 |
|---|---|
| 顶部设备栏（在线/休眠、USB/2.4G/BT、电量徽章） | ✅ |
| 键鼠双工作台切换 | ✅ |
| FLX3 四大 Tab（按键/DPI/性能/其他） | ✅ UI 就绪 |
| 休眠感知 + pending_sync + 唤醒同步 | ✅ |
| Mock 虚拟设备（GANSS_FLX3_MOCK=1） | ✅ |

## 三、未完成 / 待实现 ⚠️

### 3.1 关键缺口（当前焦点）
1. **FLX3 命令 status=0 问题**（seize 通道）
   - 官方报文重放也 0 → 差异在传输层。WebHID 调试台已证明 WebHID 通路全通（遥测实时）
   - **待办**：从 webhid.html 抓用户点按钮后的 ACK status；若 WebHID 下 status=1，
     则把「WebHID 桥」作为 FLX3 的 macOS 传输层（后台用 Chrome CDP 驱动本地页面，
     或引导用户保留一个已授权的浏览器 tab）
2. **FLX3 功能与官方对齐**：回报率/DPI/按键/宏写入的端到端实机验证（依赖上一条）
3. **键盘 Fn 层整层下发**、全键恢复默认的 UI 入口（协议已就绪，前端缺入口）
4. **宏录制器**（键盘）：录键 → t_macrorecord 模型 → `04 15` 分块下发
   —— 键盘宏事件编码仍未破解（新固件走 `SET_MACRO=37` 路线，需确认 DSM24 是否响应）

### 3.2 体验缺口（用户吐槽「简陋不如官方」的直接回应）
1. **主工作台 UI 与 webhid.html 两张皮** —— 需要把 WebHID 通道合并进主框架：
   后端开一个「WebHID 桥」WebSocket 端点，前端连接后所有 FLX3 操作走浏览器 HID
   （授权一次持久化，体验与官方完全一致且功能本地化）
2. 键盘画布缺官方质感：无键盘渲染图（keymap.json 有 keyboard.png 底图未用）、
   无实时键位反馈动画、Fn 层切换无过渡
3. 缺「配置模板库」（办公/游戏/Mac 键位交换一键套用）
4. 缺固件升级入口（`20 03` 协议已有逆向，未接 UI）
5. 打包分发（阶段 4 未开始）：PyInstaller .app / Windows exe、GitHub Actions、签名文档

### 3.3 工程债
1. `ref-cubewhy`、`ganss-mac` 旧目录待归档清理
2. 测试覆盖：键盘协议无单元测试（FLX3 有 38 项黄金测试）
3. `macos_scan.py`/`macos.py`（旧 ctypes 实现）与 framework 并存待删
4. 错误信息用户友好度（部分直接抛 OSError 原文）

## 四、建议的下一步（优先级排序）

1. **FLX3 WebHID 桥整合**（最高价值）：在 webhid.html 验证 status 后，
   把 WebHID 作为 FLX3 的首选通道做进主 UI —— 彻底解决 status=0，体验对齐官方
2. 键盘宏：先在本地页面用 `SET_MACRO(37)` 试探 DSM24 固件响应，成功则宏功能全解锁
3. UI 质感升级：键盘底图渲染 + 官方式交互细节
4. 阶段 4 打包分发 + CONTRIBUTING.md + 开源发布
