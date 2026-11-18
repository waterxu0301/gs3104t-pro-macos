# GANSS Device Hub

本地化、插件化、跨平台的开源键鼠驱动框架。首两款设备：

| 设备 | 类型 | 通道 | 功能 |
|---|---|---|---|
| GANSS GS3104T PRO 键盘（DSM24 批次） | keyboard | 2.4G 接收器 / USB / BT(只读) | 灯光、单键/组合键/媒体键/禁用键/宏绑定映射、整层下发、配置文件 |
| GANSS FLX3 鼠标 | mouse | 2.4G 接收器 / USB | 按键映射、多档 DPI、回报率、LOD、电源、Sensor 高阶、灯光、宏、出厂恢复（经 WebHID 桥） |

**数据不出本机**——服务只绑定 `127.0.0.1:8340`，无云端依赖。

## 架构

```
浏览器 UI (Material Design 3, framework/web/)
  ├── JSON API (framework/api.py, api_version 2)
  │     ├── 后端 hidapi 通道 (framework/transport.py)
  │     │     └── plugins/<device>/driver.py → BaseDeviceDriver
  │     └── FLX3 走浏览器 WebHID 桥（与官方驱动同款传输层，授权一次持久化）
  ├── SafetyGuard 双模式安全写入 (framework/safety.py)
  │     ├── HARDWARE_READBACK — 读→改→写→回读校验→回滚
  │     └── SHADOW_STATE_ACK — 本地 shadow 基线→下发→逐包 ACK→原子落盘
  └── PluginManager (manifest.json 多条件 AND 匹配，防 VID 混叠/触控板误伤)
```

## 快速开始（macOS）

```sh
git clone <repo> && cd GANSS_Drive
./start.sh          # 端口清理 + 启动 http://127.0.0.1:8340/
```

依赖：Python 3.12 venv（`archive/ganss-mac/.venv` 内含 `hidapi`），
可选 `pip install pyobjc`（FLX3 seize 通道）。

FLX3 首次使用需在页面点击「授权浏览器直连」，Chrome 弹出 WebHID 选择器中
选一次鼠标（授权持久化，与官方驱动同款传输层）。

### Gatekeeper（macOS）

`codesign -s -` 签名的 app 首次打开若被拦截：

```sh
xattr -cr /Applications/GanssDriver.app
```

## 运行测试

```sh
.venv/bin/python tests/test_flx3.py         # 38 项鼠标黄金报文
.venv/bin/python tests/test_kb_protocol.py  # 24 项键盘协议
```

## 已知限制

- 键盘映射生效前需按 **Fn+Tab** 开启「驱动自定义按键」模式（DSM24 固件）
- 键盘蓝牙模式固件不暴露配置通道，仅展示设备状态
- 5 分钟无操作键盘自动休眠，写入会触发唤醒重试（按任意键可加速）

## 致谢

协议逆向基于 [yunjianj/GANSS_GS3104T_Pro](https://github.com/yunjianj/GANSS_GS3104T_Pro)
（MIT），其 `NOTICE.md` 归档于 `ref-yunjianj/`。FLX3 协议来自对官方网页驱动
JS 的静态分析（`analysis/FLX3_逆向报告.md`）。非官方软件，与 GANSS/HFD/SONiX/
远大芯科技无隶属关系。
