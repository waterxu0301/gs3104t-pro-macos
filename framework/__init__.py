def __getattr__(name):
    if name == 'Api':
        from .api import Api
        return Api
    if name == 'PluginManager':
        from .plugin_manager import PluginManager
        return PluginManager
    raise AttributeError(name)
