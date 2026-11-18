"""Cross-platform HID transport based on the `hid` Cython binding.

Report ID conventions (the critical pitfall this layer normalizes):

- Python hidapi requires the report ID as buf[0] of every buffer.
- `send_feature(report_id, payload)`: for report_id == 0 (no numbered reports,
  e.g. GS3104T keyboard) buf[0] = 0x00 + payload; for numbered devices
  (e.g. FLX3 mouse, reportId 6/5) buf[0] = report_id + payload.
- `get_feature(report_id, length)`: returns the raw API buffer. Callers should
  use `strip_report_id` helper; per-device layouts differ (some stacks return
  the buffer without the leading ID, see normalize below).
- `poll_input`: hidapi read() always includes the report ID at buf[0] for
  numbered devices; unnumbered keyboards return data starting at offset 0.
  poll_input returns (report_id, payload) so plugins index safely.

The layer never guesses device layouts: each plugin declares which shape it
speaks through its driver code.
"""
import time

import hid

from .errors import TransportError


class HidTransport:
    """One open HID endpoint. Wraps hid.device with explicit report-id handling."""

    def __init__(self, device_path, numbered_reports=False):
        self.path = device_path
        self.dev = None
        self.numbered_reports = numbered_reports  # True for FLX3-style devices

    def open(self):
        try:
            self.dev = hid.device()
            path = self.path.decode('utf-8') if isinstance(self.path, bytes) else self.path
            self.dev.open_path(path.encode('utf-8'))
        except (OSError, ValueError) as e:
            raise TransportError(f'无法打开 HID 设备 {self.path}: {e}') from e
        # Drivers that need numbered reports (FLX3) pass numbered_reports=True;
        # unnumbered keyboards (GS3104T) keep False.
        self._numbered = self.numbered_reports
        return self

    def close(self):
        if self.dev:
            self.dev.close()
            self.dev = None

    def __enter__(self):
        return self.open()

    def __exit__(self, *_):
        self.close()

    # ---- feature reports -------------------------------------------------

    def send_feature(self, report_id, payload):
        """payload excludes the report ID. Cython API takes the buffer with
        report_num as first byte for numbered devices; for report_id=0 the
        IOKit backend expects the data without a leading zero."""
        if report_id == 0:
            buf = bytes(payload)
        else:
            buf = bytes([report_id]) + bytes(payload)
        n = self.dev.send_feature_report(buf)
        if n != len(buf):
            raise TransportError(f'Feature 写入不完整: {n}/{len(buf)}')

    def get_feature(self, report_id, length):
        """Returns raw response bytes. Cython hid.device API takes report_num
        directly and returns the payload (report ID excluded on macOS IOKit)."""
        data = self.dev.get_feature_report(report_id, length + 1)
        if data is None or (isinstance(data, list) and len(data) == 0):
            raise TransportError('Feature 读取失败')
        return bytes(data)

    # ---- output / input --------------------------------------------------

    def write_output(self, report_id, payload):
        if report_id == 0:
            buf = b'\x00' + bytes(payload)
        else:
            buf = bytes([report_id]) + bytes(payload)
        n = self.dev.write(buf)
        if n != len(buf):
            raise TransportError(f'Output 写入不完整: {n}/{len(buf)}')

    def poll_input(self, max_len, timeout_ms=10):
        """Drain one pending input report. Returns (report_id, payload) or None.

        Unnumbered devices: hidapi returns raw data whose first byte is
        business data (e.g. GS3104T echo starts 05 10 00) — report as (0, data).
        Numbered devices (FLX3): hidapi returns [report_id, ...]; detected via
        the device's numbered-report flag probed at open time, NOT guessed
        from the first byte's value.
        """
        data = self.dev.read(max_len, timeout_ms)
        if not data:
            return None
        return (self._numbered, bytes(data)[1:]) if self._numbered else (0, bytes(data))


def split_report_id(raw):
    """Normalize a get_feature response: if buf[0] matches a nonzero report
    id context the caller strips; unnumbered responses may arrive with or
    without the leading zero. Returns payload bytes (ID stripped)."""
    if raw and raw[0] == 0 and len(raw) > 1:
        return raw[1:]
    return raw
