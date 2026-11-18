# 新设备接入指南

本框架的目标是让社区用 **一个 manifest + 一个 driver 文件** 接入新型号键鼠。

## 1. 目录结构

```
framework/plugins/<your_device>/
├── manifest.json     # 设备声明（匹配规则、能力、UI 装配、安全模式）
├── driver.py         # class Driver(BaseDeviceDriver)
├── protocol.py       # 报文编码器（纯函数，便于黄金测试）
└── data/             # 布局坐标、图标等静态数据
```

## 2. manifest.json 字段

```jsonc
{
  "spec_version": 1,
  "plugin_id": "vendor_model",           // 全局唯一
  "name": "显示名",
  "device_type": "keyboard",             // keyboard | mouse
  "match": [                             // AND 条件，命中任一条即匹配
    {"vid": "0x1234", "pid": ["0x5678"],
     "product_regex": "(?i)MODEL",       // 强烈建议：防 VID 混叠
     "usage_page": "0xFF00"}             // 配置通道页
  ],
  "capabilities": ["lighting", "keymap"],
  "ui_modules": [                        // 前端自动装配
    {"component": "lighting-panel", "props": {"modes": 19}}
  ],
  "safety": {
    "default_mode": "SHADOW_STATE_ACK",  // 无回读用此；有回读用 HARDWARE_READBACK
    "modules": {"keymap": "SHADOW_STATE_ACK"}
  }
}
```

> **VID 混叠警告**：部分厂商混叠 VID（如 GANSS 键盘用 Apple 05AC），
> 或共享方案商 VID（如 04F3 Elan 也用于笔记本触摸板）。
> **必须**组合 `product_regex` 或 `usage_page`，严禁单一 VID 匹配。

## 3. Driver 最小实现

```python
from framework.base_driver import BaseDeviceDriver

class Driver(BaseDeviceDriver):
    plugin_id = "vendor_model"

    def match(self, hid_entry, manifest): return True        # 已被 manifest 预筛
    def pick_endpoint(self, endpoints):
        return {"path": endpoints[0]["path"], "connection": "wired"}
    def probe(self, transport, connection):
        return {"name": "...", "connection": connection}
    def read_state(self, transport, connection):
        return {"connection": connection, "shadow": self._shadow()}
    def apply_config(self, transport, connection, module, patch):
        # 强制流程：读基线 → patch → 整块下发 → 校验
        ...
    def reset_default(self, transport, connection, scope, layer="normal"): ...
    def keys_list(self): return []
```

浏览器直连（推荐用于鼠标类、macOS 被独占的接口）：

```python
def open_transport(self, endpoint):
    from framework.transport import HidTransport
    return HidTransport(endpoint["path"], numbered_reports=True).open()
```

## 4. 安全写入规范（必须遵守）

- **HARDWARE_READBACK**：读块 → patch → 写 → 读回比对 → 重试 1 次 → 回滚
- **SHADOW_STATE_ACK**：`framework.safety.load_shadow/save_shadow` 管理基线，
  写入后逐包校验硬件 echo/ACK，全部成功才原子落盘
- 禁止盲写整块；禁止在未校验时更新 shadow
- UI 必须区分「硬件确认」与「仅本地保存」两种提示

## 5. 黄金测试

每个 protocol.py 必须配 `tests/test_<device>.py`：
覆盖每条命令的 32B/65B/33B 完整缓冲区、checksum 位置与跳过规则、
槽位交换（如有）、填充字节（0 vs 0xFF）。参考 `tests/test_flx3.py`。

## 6. 提交 PR

1. `git checkout -b plugin/<device>`
2. 通过全部测试 + 真机验证（在 `analysis/` 附验证记录）
3. 更新 README 支持设备表
