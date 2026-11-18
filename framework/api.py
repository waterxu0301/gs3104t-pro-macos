"""Unified JSON API routed through PluginManager.

api_version 2. Methods:
  plugins.list / plugins.set_enabled / plugins.remove
  devices.scan
  device.state      {device}
  device.apply      {device, module, patch}
  device.reset      {device, scope}
  keys.list         {device}  (keyboard plugins expose layout data)
"""
import threading

from .errors import ConfigError, FrameworkError
from .plugin_manager import PluginManager

_api_lock = threading.Lock()


def _fields(value, allowed, required=()):
    if not isinstance(value, dict):
        raise ConfigError('参数必须为 JSON 对象')
    extra = set(value) - set(allowed)
    if extra:
        raise ConfigError('未知字段: ' + ', '.join(sorted(extra)))
    missing = set(required) - set(value)
    if missing:
        raise ConfigError('缺少字段: ' + ', '.join(sorted(missing)))


class Api:
    def __init__(self, manager=None):
        self.pm = manager or PluginManager()

    def dispatch(self, request):
        request_id = request.get('id') if isinstance(request, dict) else None
        try:
            result = self._handle(request)
            return {'api_version': 2, 'id': request_id, 'ok': True, 'result': result}
        except FrameworkError as e:
            return {'api_version': 2, 'id': request_id, 'ok': False,
                    'error': {'code': e.code, 'message': str(e),
                              'may_have_partial_changes': e.may_have_partial_changes}}
        except Exception as e:  # unexpected → honest generic error
            return {'api_version': 2, 'id': request_id, 'ok': False,
                    'error': {'code': 'internal_error', 'message': f'{type(e).__name__}: {e}',
                              'may_have_partial_changes': False}}

    def _handle(self, request):
        _fields(request, ('id', 'api_version', 'method', 'params'), ('api_version', 'method'))
        if request['api_version'] != 2:
            raise ConfigError('api_version 必须为 2')
        method, params = request['method'], request.get('params', {})

        if method == 'plugins.list':
            _fields(params, ())
            return {'plugins': self.pm.list_plugins()}
        if method == 'plugins.set_enabled':
            _fields(params, ('plugin_id', 'enabled'), ('plugin_id', 'enabled'))
            self.pm.set_enabled(params['plugin_id'], params['enabled'])
            return {'plugins': self.pm.list_plugins()}
        if method == 'plugins.remove':
            _fields(params, ('plugin_id',), ('plugin_id',))
            self.pm.remove_plugin(params['plugin_id'])
            return {'plugins': self.pm.list_plugins()}
        if method == 'devices.scan':
            _fields(params, ())
            return {'devices': self.pm.enumerate_all()}

        # device-scoped methods
        _fields(params, ('device', 'module', 'patch', 'scope'),
                ('device',))
        with _api_lock:
            plugin_id, driver, manifest, device = self.pm.resolve_device(params['device'])
            conn = self._open_connection(plugin_id, driver, device)
            try:
                if method == 'device.state':
                    return {'device': device, 'state': driver.read_state(*conn)}
                if method == 'device.apply':
                    _fields(params, ('device', 'module', 'patch'), ('device', 'module', 'patch'))
                    return {'device': device,
                            'apply': driver.apply_config(*conn, params['module'], params['patch'])}
                if method == 'device.reset':
                    scope = params.get('scope', 'all')
                    return {'device': device,
                            'reset': driver.reset_default(*conn, scope)}
                if method == 'keys.list':
                    return {'keys': driver.keys_list()}
                raise ConfigError(f'未知方法: {method}')
            finally:
                conn[0].close()

    def _open_connection(self, plugin_id, driver, device):
        from .transport import HidTransport
        endpoints = []
        for e in device['endpoints']:
            path = e['path']
            if isinstance(path, str):
                path = path.encode('utf-8')
            endpoints.append({'path': path, 'usage_page': int(e['usage_page'], 16),
                              'interface_number': e['interface_number'],
                              'vendor_id': 0, 'product_id': 0, 'product_string': '',
                              'serial_number': '', 'usage': 0})
        endpoint = driver.pick_endpoint(endpoints)
        t = HidTransport(endpoint['path']).open()
        return t, endpoint['connection']
