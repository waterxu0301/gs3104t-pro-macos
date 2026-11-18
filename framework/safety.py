"""Dual-mode safety guard for device writes.

Level 1 HARDWARE_READBACK  : read block -> patch -> write -> read back ->
                              compare -> retry once -> rollback on failure.
Level 2 SHADOW_STATE_ACK    : local profiles.json is the baseline source ->
                              patch -> write full block -> verify every step's
                              hardware echo/ACK -> atomically persist shadow.
"""
import copy
import json
import os
import tempfile
from pathlib import Path

from .errors import TransferError

SHADOW_DIR = Path.home() / '.config' / 'ganss-driver'


def shadow_path(plugin_id):
    return SHADOW_DIR / f'{plugin_id}-shadow.json'


def load_shadow(plugin_id, default_factory):
    p = shadow_path(plugin_id)
    if p.exists():
        try:
            return json.loads(p.read_text(encoding='utf-8'))
        except (json.JSONDecodeError, OSError):
            pass
    shadow = default_factory()
    save_shadow(plugin_id, shadow)
    return shadow


def save_shadow(plugin_id, shadow):
    p = shadow_path(plugin_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=f'.{plugin_id}-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(shadow, f, ensure_ascii=False, indent=2)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


class SafetyGuard:
    """Manifest-declared verification per module:
    manifest.safety.modules = { "<module>": "HARDWARE_READBACK"|"SHADOW_STATE_ACK" }
    Default when undeclared: SHADOW_STATE_ACK."""

    def __init__(self, manifest):
        modules = (manifest.get('safety') or {}).get('modules', {})
        self.modules = modules
        self.plugin_id = manifest.get('plugin_id', 'unknown')

    def mode_for(self, module):
        return self.modules.get(module, 'SHADOW_STATE_ACK')

    def verify_readback(self, read_block_fn, patched_block, max_attempts=2):
        """Level 1. read_block_fn() -> bytes|dict. Retries once; raises with
        rollback obligation on persistent mismatch."""
        for attempt in range(max_attempts):
            current = read_block_fn()
            if current == patched_block:
                return True
        raise TransferError('回读校验失败：硬件状态与期望不一致，请重新应用配置')

    def verify_ack(self, step_results):
        """Level 2. step_results: list of (label, ok:bool). All must pass."""
        for label, ok in step_results:
            if not ok:
                raise TransferError(f'步骤「{label}」硬件确认失败；配置可能处于部分写入状态')

    def persist(self, shadow):
        save_shadow(self.plugin_id, shadow)

    def patch_shadow(self, shadow, path, value):
        """Deep-copy patch helper: path like ['dpi', 'levels']."""
        result = copy.deepcopy(shadow)
        node = result
        for key in path[:-1]:
            node = node.setdefault(key, {})
        node[path[-1]] = value
        return result
