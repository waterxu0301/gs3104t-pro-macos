"""Versioned JSON API for the web frontend, dispatching on macOS transports."""
import json
import threading

from .protocol import BY_INDEX, ConfigError, keymap_plan, keymap_single_plan, light_plan
from .runner import ProtocolError, execute
from .macos_scan import public_hardware, scan_hardware, select_hardware, select_transport
from .macos import MacHid

_lock = threading.Lock()


def _fields(value, allowed, required=()):
    if not isinstance(value, dict):
        raise ConfigError('参数必须为 JSON 对象')
    if set(value) - set(allowed):
        raise ConfigError('未知字段: ' + ', '.join(sorted(set(value) - set(allowed))))
    if set(required) - set(value):
        raise ConfigError('缺少字段: ' + ', '.join(sorted(set(required) - set(value))))


def _open_transport(hardware, connection):
    endpoints, by_if = select_transport(hardware)
    preferred = 4 if connection == 'usb' else 3
    endpoint = by_if.get(preferred) or endpoints[0]
    # mac transport decides per-plan channel; hand over both endpoints' paths
    return MacHid(endpoint['path'], connection), endpoint


def _handle(request):
    _fields(request, ('id', 'api_version', 'method', 'params'), ('api_version', 'method'))
    if type(request['api_version']) is not int or request['api_version'] != 1:
        raise ConfigError('api_version 必须为 1')
    method, params = request['method'], request.get('params', {})
    if not isinstance(method, str):
        raise ConfigError('method 必须为字符串')
    if method == 'devices.scan':
        _fields(params, ())
        return {'devices': [public_hardware(h) for h in scan_hardware()]}
    if method == 'keys.list':
        _fields(params, ())
        return {'keys': [{'index': i, 'name': k['name'], 'usage': k['code']}
                         for i, k in sorted(BY_INDEX.items())]}
    options = {
        'lighting.set': ('mode', 'brightness', 'speed', 'color', 'colorful'),
        'keymap.set': ('source', 'target', 'layer'),
        'keymap.apply': ('profile',),
    }
    if method not in options:
        raise ConfigError(f'未知方法: {method}')
    required = {'keymap.set': ('source', 'target'), 'keymap.apply': ('profile',)}.get(method, ())
    _fields(params, ('device', 'dry_run') + options[method], ('device',) + required)
    if not isinstance(params['device'], str) or not params['device']:
        raise ConfigError('device 必须为扫描得到的硬件名或 ID')
    if type(params.get('dry_run', False)) is not bool:
        raise ConfigError('dry_run 必须为布尔值')
    if 'colorful' in params and type(params['colorful']) is not bool:
        raise ConfigError('colorful 必须为布尔值')

    hardware = select_hardware(params['device'])
    endpoints, by_if = select_transport(hardware)
    args = {k: params[k] for k in options[method] if k in params}
    if method == 'lighting.set':
        plan = light_plan(**args, connection='wireless' if by_if.get(3) else 'usb')
    elif method == 'keymap.set':
        plan = keymap_single_plan(**args, connection='wireless' if by_if.get(3) else 'usb')
    else:
        plan = keymap_plan(params['profile'], 'wireless' if by_if.get(3) else 'usb')

    channels = {step.channel for step in plan}
    preferred = 3 if 'short' in channels else 4
    endpoint = by_if.get(preferred) or endpoints[0]

    result = {'device': public_hardware(hardware), 'endpoint': endpoint['path'],
              'dry_run': params.get('dry_run', False),
              'replaces_entire_layer': method == 'keymap.apply',
              'warnings': ['若映射未生效，请检查 Fn+Tab 是否屏蔽驱动自定义按键指令。']
                          if method.startswith('keymap.') else []}
    if result['dry_run']:
        result.update(steps=[step.as_dict() for step in plan], status='planned')
        return result
    trace = []
    with _lock:
        with MacHid(endpoint['path'], 'wireless' if 'short' in channels else 'usb',
                    trace.append) as transport:
            completed = execute(plan, transport)
    result.update(status='transferred', completed_steps=completed, trace=trace,
                  effect_verified=False, persistence_verified=False)
    return result


def dispatch(request):
    request_id = request.get('id') if isinstance(request, dict) else None
    if request_id is not None and type(request_id) not in (str, int):
        return _error(None, 'invalid_request', 'id 必须为字符串、整数或 null')
    try:
        return {'api_version': 1, 'id': request_id, 'ok': True, 'result': _handle(request)}
    except ConfigError as e:
        return _error(request_id, 'invalid_request', str(e))
    except PermissionError as e:
        return _error(request_id, 'permission_denied', str(e))
    except ProtocolError as e:
        return _error(request_id, 'transfer_failed', str(e), partial=True)
    except (TimeoutError, OSError) as e:
        return _error(request_id, 'device_io_error', str(e))


def _error(request_id, code, message, partial=False):
    return {'api_version': 1, 'id': request_id, 'ok': False,
            'error': {'code': code, 'message': message, 'may_have_partial_changes': partial}}
