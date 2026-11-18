# GANSS GS3104T PRO — macOS 本地驱动

本地网页版键盘驱动，用于在 **macOS** 上配置 GANSS GS3104T PRO（2.4G 接收器 / USB 有线）。
键盘序列号以 DSM 开头的批次无法使用官方网页驱动（ganss.driveall.cn，WebHID 只认 DSMW 前缀
的 VID/PID），本工具不依赖浏览器 HID 权限，直接通过本地 HID 通道通信。

## 功能

- 灯光：19 种官方灯效 + 关闭背光，颜色 / 亮度 / 速度可调
- 按键映射：普通层 / Fn 层单键映射（2.4G 通道），映射目标支持组合修饰键如 `CTRL+C`
- 本地运行：HTTP 服务只绑定 127.0.0.1，数据不出本机

## 运行

```sh
cd ganss-mac
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python hidapi   # 提供 Python hid 绑定（自带 hidapi 源码）
.venv/bin/python -m ganss
# 打开 http://127.0.0.1:8340/
```

若提示找不到 hidapi 动态库：`brew install hidapi`。

## 注意事项

- 映射前确认键盘处于「驱动自定义按键」开启状态（说明书：**Fn+Tab** 切换）。
- 写入成功（`transferred`）只代表指令通道确认，不代表效果已验证；界面会提示你确认实际效果。
- 固件升级（`SN32F290.hex`，需有线模式）暂未纳入本工具；请用 Windows 虚拟机或官方 ISP 工具。
- macOS 上键盘的常规打字接口可能被系统独占；本工具只使用 FF60 vendor 配置接口。

## 来源与致谢

协议来自对官方 Windows 驱动 (1.0.0.3) 的静态逆向，实现在
[yunjianj/GANSS_GS3104T_Pro](https://github.com/yunjianj/GANSS_GS3104T_Pro)
（MIT，见其 NOTICE.md）。本项目复用其 `protocol.py` / `runner.py` / `light_modes.py` /
`profiles.py` 与键位表，重写了 macOS IOKit 传输层（ctypes + hidapi）和 Web 前端。

非官方软件，与 GANSS / HFD / SONiX 无隶属关系。使用风险自负；错误的整层映射可通过
`keymap.apply` 恢复，或刷官方固件复位。
