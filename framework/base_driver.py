"""BaseDeviceDriver: abstract lifecycle every device plugin must implement.

A driver instance is created per matched physical device by PluginManager.
All transport access goes through the HidTransport passed to connect().
"""
import abc


class BaseDeviceDriver(abc.ABC):
    # Subclasses set these from their manifest for fast access.
    plugin_id = None

    @abc.abstractmethod
    def match(self, hid_entry, manifest):
        """Return True if this hidapi enumeration entry belongs to us.
        Multi-condition AND matching (vid/pid/usage_page/product_regex).
        Called only for entries whose VID/PID a manifest lists OR whose
        product_regex matches, never for unrelated HID hardware."""

    @abc.abstractmethod
    def probe(self, transport, connection):
        """Cheap read-only channel check after open. Raise on mismatch.
        Returns dict of basic info (name, serial, connection)."""

    @abc.abstractmethod
    def read_state(self, transport, connection):
        """Best-effort live state snapshot (battery, current levels...).
        May return {} when the device has no live-state channel."""

    @abc.abstractmethod
    def apply_config(self, transport, connection, patch, shadow):
        """Apply a config patch. Receives the shadow baseline dict; returns
        (updated_shadow, report) where report describes what was verified."""

    @abc.abstractmethod
    def reset_default(self, transport, connection, scope, shadow):
        """Restore defaults for scope ('key'/'layer'/'all')."""

    def scan_endpoints(self, hid_entries):
        """Group enumeration entries into physical devices.
        Default: group by (vendor_id, product_id, serial/product)."""
        groups = {}
        for e in hid_entries:
            key = (e['vendor_id'], e['product_id'], e['serial_number'] or e['product_string'])
            groups.setdefault(key, []).append(e)
        return list(groups.values())
