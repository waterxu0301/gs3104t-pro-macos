"""Framework-level exception types mapped to API error codes."""


class FrameworkError(Exception):
    code = 'internal_error'
    may_have_partial_changes = False


class TransportError(FrameworkError):
    code = 'device_io_error'
    may_have_partial_changes = True


class DeviceError(FrameworkError):
    code = 'device_error'


class ConfigError(FrameworkError):
    code = 'invalid_request'


class TransferError(FrameworkError):
    code = 'transfer_failed'
    may_have_partial_changes = True
