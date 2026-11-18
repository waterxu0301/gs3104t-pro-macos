"""Virtual FLX3 device for UI preview without hardware.

Registered via API devices.scan when GANSS_FLX3_MOCK=1 env var is set, or
plugins.set_enabled on plugin id 'ganss_flx3' with state.mock = true."""
import os


def mock_enabled():
    return os.environ.get('GANSS_FLX3_MOCK') == '1'


class MockDevice:
    device_id = 'ganss_flx3:mock'
    plugin_id = 'ganss_flx3'
    device_type = 'mouse'
    capabilities = ["keymap", "dpi", "polling_rate", "lod", "battery",
                    "lighting", "macro", "power", "sensor_tuning", "factory_reset"]
    name = 'GANSS FLX3 (虚拟预览)'

    def as_device(self):
        return {'device_id': self.device_id, 'plugin_id': self.plugin_id,
                'device_type': self.device_type, 'capabilities': self.capabilities,
                'name': self.name, 'connection': 'wired', 'online': True,
                'battery': 90, 'sensorType': 149, 'sensor': '3395 (虚拟)',
                'endpoints': [], 'mock': True}
