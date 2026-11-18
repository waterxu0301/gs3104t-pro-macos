"""GANSS FLX3 mouse protocol — Report ID 6 feature + checksum model.

Byte-exact per analysis/FLX3_逆向报告.md (web driver static extraction):
- Logical array [cmd, seq, subcmd, X, payload...] padded to 31 bytes,
  then setCheckSum inserts (6 + Σ(skip idx3)) & 0xFF at index 3 → 32 bytes.
- Sent via send_feature_report(report_id=6, 32-byte buffer).
- ACK: receive_feature_report(6) → getUint8(1) == 1 (WebHID DataView
  includes report ID at [0]; hidapi Cython on macOS returns payload without
  the ID for numbered devices... actually it INCLUDES it — normalized in
  transport; here we accept both shapes).
- Status/state: receiveFeatureReport(5) snapshot; input report ID 4 carries
  live telemetry (linkStatus, level, rate, battery, ..., sensorType).
"""
import struct
import time

REPORT_CMD = 6
REPORT_STATE = 5
REPORT_INPUT = 4

# sensor configs: type -> (name, step divisor, max dpi)
SENSORS = {
    17: ('3311', 100, 12000),
    149: ('3395', 50, 26000),
    80: ('3950', 50, 30000),
    32: ('3220', 100, 8000),
    18: ('3212', 100, 4800),
    9: ('3809', 100, 6000),
    6: ('S205', 100, 12800),
    112: ('OM70', 100, 30000),
}
DEFAULT_SENSOR = 149
DEFAULT_MAX_RATE = 2  # 1000Hz index per FLX3_BK_2K naming

POLLING_RATES = {8: 125, 4: 250, 2: 500, 1: 1000, 17: 2000, 18: 4000, 20: 8000}
LIGHT_MODES = {0: '关闭', 1: '混彩流光', 2: '呼吸', 3: '常亮',
               4: '霓虹', 5: '跑马', 6: '混彩常亮', 7: '七彩波浪'}

# button record types
BTN_MOUSE = 16
BTN_FIRE = 48
BTN_DPI = 64
BTN_DPI_LOCK = 80
BTN_SPECIAL = 96      # [96,0,0]=disable, [96,4,0]=lighting toggle
BTN_COMBO = 112
BTN_MEDIA = 128
BTN_MACRO = 144

MOUSE_BUTTONS = {1: '左键', 2: '右键', 4: '中键', 8: '后退', 16: '前进'}


def set_checksum(logical):
    """Insert checksum at index 3 of a logical command array, returning the
    32-byte physical buffer. sum = (6 + Σ bytes skipping idx3) & 0xFF.
    IMPORTANT: original idx3 value does NOT participate in the sum and gets
    shifted to idx4 (verified against official JS setCheckSum)."""
    data = bytearray(logical[:31])
    total = 6
    for i, v in enumerate(data):
        if i != 3:
            total += v
    data.insert(3, total & 0xFF)
    data = data[:32]
    while len(data) < 32:
        data.append(0)
    return bytes(data)


class Seq:
    def __init__(self):
        self._v = 0

    def next(self):
        self._v = (self._v + 1) % 256
        return self._v


def parse_input_report(payload):
    """reportId=4 telemetry. Accepts payload with or without the leading
    report ID. Field offsets per web driver oninputreport handler."""
    b = payload[1:] if payload and payload[0] == REPORT_INPUT and len(payload) > 8 else payload
    if len(b) < 9:
        return None
    return {
        'linkStatus': b[0],
        'currentLevel': b[1],
        'currentReportRate': b[2],
        'batteryLevel': b[3],
        'batteryStatus': b[4],
        'lightEffectMode': b[5],
        'maxReportRate': b[7],
        'sensorType': b[8] or DEFAULT_SENSOR,
    }


# ---- record encoders (3 bytes each) ---------------------------------------

def encode_button_record(spec):
    """spec: dict or shorthand string.
    Shorthands: 'default', 'disable', 'dpi_cycle', 'dpi_up', 'dpi_down',
                'dpi_lock:N', 'light_toggle', 'fire:interval:count',
                'media:播放暂停', 'LCtrl+C', 'macro:N', 'mouse:左键'"""
    if spec in (None, '', 'default'):
        return None  # unconfigured: caller pads 255,255,255
    if spec == 'disable':
        return (BTN_SPECIAL, 0, 0)
    if spec == 'dpi_cycle':
        return (BTN_DPI, 1, 0)
    if spec == 'dpi_up':
        return (BTN_DPI, 2, 0)
    if spec == 'dpi_down':
        return (BTN_DPI, 3, 0)
    if spec == 'light_toggle':
        return (BTN_SPECIAL, 4, 0)
    if spec.startswith('dpi_lock:'):
        return (BTN_DPI_LOCK, int(spec[9:]), 0)
    if spec.startswith('fire:'):
        _, interval, count = spec.split(':')
        return (BTN_FIRE, int(interval), int(count))
    if spec.startswith('media:'):
        usage = MEDIA_CONSUMER[spec[6:]]
        return (BTN_MEDIA, usage & 0xFF, (usage >> 8) & 0xFF)
    if spec.startswith('macro:'):
        # [144, H<<4|slot, repeat] — web driver semantics simplified for
        # binding: slot in low nibble of byte2
        return (BTN_MACRO, 0, 0)
    if spec.startswith('mouse:'):
        return (BTN_MOUSE, MOUSE_USAGE[spec[6:]], 0)
    # keyboard combo
    mask, usage = 0, None
    for part in spec.split('+'):
        part = part.strip()
        if part in MODIFIERS:
            mask |= MODIFIERS[part]
        else:
            try:
                usage = int(part, 0)
            except ValueError:
                usage = _lookup_usage(part)
    if usage is None:
        raise ValueError(f'{spec} 缺少普通键')
    return (BTN_COMBO, mask, usage)


MEDIA_CONSUMER = {
    '播放暂停': 0x00CD, '播放停止': 0x00B7, '上一曲': 0x00B6, '下一曲': 0x00B5,
    '音量+': 0x00E9, '音量-': 0x00EA, '静音': 0x00E2, '计算器': 0x0192,
    '邮箱': 0x018A, '多媒体': 0x0183, '主页': 0x0223, '刷新': 0x0227,
    '前进': 0x0225, '后退': 0x0224, '收藏': 0x022A, '搜索': 0x0221,
}
MOUSE_USAGE = {'左键': 1, '右键': 2, '中键': 4, '后退': 8, '前进': 16}
MODIFIERS = {'LCtrl': 1, 'LShift': 2, 'LAlt': 4, 'LWin': 8,
             'RCtrl': 16, 'RShift': 32, 'RAlt': 64, 'RWin': 128}

_USAGE_ALIASES = {
    'a': 0x04, 'b': 0x05, 'c': 0x06, 'd': 0x07, 'e': 0x08, 'f': 0x09, 'g': 0x0A,
    'h': 0x0B, 'i': 0x0C, 'j': 0x0D, 'k': 0x0E, 'l': 0x0F, 'm': 0x10, 'n': 0x11,
    'o': 0x12, 'p': 0x13, 'q': 0x14, 'r': 0x15, 's': 0x16, 't': 0x17, 'u': 0x18,
    'v': 0x19, 'w': 0x1A, 'x': 0x1B, 'y': 0x1C, 'z': 0x1D,
    'enter': 0x28, 'esc': 0x29, 'backspace': 0x2A, 'tab': 0x2B, 'space': 0x2C,
    'f1': 0x3A, 'f12': 0x45, 'left': 0x50, 'right': 0x4F, 'up': 0x52, 'down': 0x51,
}


def _lookup_usage(name):
    v = _USAGE_ALIASES.get(name.lower())
    if v is None:
        raise ValueError(f'未知按键: {name}')
    return v


def encode_keymap_packet(buttons, seq):
    """buttons: dict buttonNo(1..6) → shorthand/None. Physical slot swap:
    payload slots 3↔4 exchanged (UI button 4 fills slot 3, button 5 fills
    slot 4) per official DeviceView.js Ct(). Returns 32B buffer."""
    logical = [1, seq, 1]
    for slot in range(9):
        # Official Ct(): `re===3?he=4:re===4&&(he=3)` — payload slot idx3
        # carries UI button 5 (array idx 4), slot idx4 carries UI button 4
        # (array idx 3). Slots otherwise 1:1.
        btn = slot + 1
        if slot == 3:
            btn = 5
        elif slot == 4:
            btn = 4
        spec = buttons.get(btn)
        rec = encode_button_record(spec) if spec else None
        if rec is None:
            logical += [255, 255, 255]
        else:
            logical += [rec[0], rec[1], rec[2]]
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


def encode_dpi_packet(axis, current_index, enabled_mask, dpi_values, sensor_type, seq):
    """axis: 'x'(2)/'y'(18). dpi_values: list up to 8. 3395/3950 step=50."""
    logical = [2, seq, 2 if axis == 'x' else 18, current_index, enabled_mask]
    step = 50 if sensor_type in (149, 80) else 100
    for i in range(8):
        dpi = dpi_values[i] if i < len(dpi_values) else 0
        reg = max(0, int(dpi // step) - 1) if dpi else 0
        logical += [reg & 0xFF, (reg >> 8) & 0xFF]
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


def encode_dpi_color_packet(colors, seq):
    """colors: list of '#RRGGBB' (8)."""
    logical = [3, seq, 1]
    for i in range(8):
        c = (colors[i] if i < len(colors) else '#EA5E56').lstrip('#')
        logical += [int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)]
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


def encode_polling_packet(rate, seq):
    logical = [4, seq, 1, rate]
    while len(logical) < 31:
        logical.append(0)
    return set_checksum(logical)


def encode_lod_packet(lod, seq):
    logical = [5, seq, 1, lod]
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


def encode_light_packet(mode, color, brightness, speed, direction=0, seq=1):
    logical = [6, seq, 1, 255, mode]
    logical.append((min(max(brightness, 1), 4) << 4) | min(max(speed, 1), 3))
    logical.append(direction)
    c = color.lstrip('#')
    logical += [int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)]
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


def encode_power_packet(sleep_time, move_wakeup, move_lighting, seq):
    logical = [7, seq, 1, min(max(sleep_time, 1), 15),
               1 if move_wakeup else 0, 1 if move_lighting else 0]
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


def encode_sensor_packet(angle_snap, motion_sync, ripple, seq):
    logical = [8, seq, 1, 1 if angle_snap else 0, 1 if motion_sync else 0,
               1 if ripple else 0]
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


def encode_reset_packet(seq):
    logical = [15, seq, 1]
    logical.append(255)
    while len(logical) < 31:
        logical.append(255)
    return set_checksum(logical)


# ---- macro ------------------------------------------------------------------

MACRO_EVENT_MOUSE = {1: 0xF0, 2: 0xF1, 4: 0xF2, 16: 0xF3, 8: 0xF4}


def encode_macro_events(events):
    """events: [{type:'key'|'delay'|'move', ...}]
    key: {isPress, key|button, keyCode, delay(=next-event delay, 12-bit)}
    delay: {delay_ms}
    move: {direction:'左/右/上/下', value, delay}
    Returns the [9,144,button,count,...] buffer per official T()/R()."""
    out = [9, 144, 0, 0]  # button index patched by caller
    data = []
    evs = sorted(events, key=lambda e: e.get('index', 0))
    for i, e in enumerate(evs):
        if e['type'] == 'delay':
            d = min(e.get('delay_ms', 0), 4095)
            data += [d >> 8 & 15, d & 255, 0]
        elif e['type'] == 'move':
            v = e.get('value', 1)
            d = min(e.get('delay_ms', 0), 4095)
            tbl = {'左': (0x40, (-v) & 255), '右': (0x41, v),
                   '上': (0x50, (-v) & 255), '下': (0x51, v)}
            head, dv = tbl.get(e.get('direction', '右'), (0x41, v))
            data += [head, d & 255, dv]
        else:  # key event
            press = bool(e.get('isPress', True))
            code = e.get('keyCode', 0)
            if code in (1, 2, 3):  # mouse buttons by index
                code = {1: 240, 2: 241, 3: 242, 4: 243, 5: 244}.get(code, 240)
            # official serializer: b0/b1 = the event's OWN delay_ms (12-bit)
            own = min(e.get('delay_ms', 0), 4095)
            b1 = own >> 8 & 15
            if code < 145:
                b1 |= 0
                final = code
            elif code < 232:
                b1 |= 32
                final = [1, 2, 4, 8, 16, 32, 64, 128][code & 7]
            elif 240 <= code <= 244:
                b1 |= 16
                final = [1, 2, 4, 8, 16, 32, 64, 128][code & 7]
            elif code == 245:
                b1 |= 64; final = code
            elif code == 246:
                b1 |= 80; final = code
            elif code == 247:
                b1 |= 96; final = code
            else:
                final = code
            # official write-side flags: actionType 1/2 → press 0x90 / release 0x10;
            # recorded keyboard (actionType 3) → press 0xB0 / release 0x30. The
            # flag ORs into b1 alongside the event's own delay high bits.
            at = e.get('actionType', 3)
            flags = (0x90 if press else 0x10) if at in (1, 2) else (0xB0 if press else 0x30)
            data += [flags | b1, own & 255, final]
    out[3] = len([e for e in evs if e['type'] != 'delay'])
    out += data
    return out


def encode_macro_erase(seq):
    logical = [17, seq, 1, 255]
    while len(logical) < 31:
        logical.append(0)
    return set_checksum(logical)


def encode_macro_chunks(buffer, button_index, seq_start=1):
    """buffer: [9,144,btn,count,...] from encode_macro_events. Chunk 25B per
    packet, packet header [16, seq, (n<<4)|total, 1+len, btn, data...]."""
    total = len(buffer) - 4
    packets_n = max(1, (total + 24) // 25)
    chunks = []
    remaining = total
    seq = Seq()
    for q in range(packets_n):
        logical = [16, seq.next()]
        logical.append((q << 4 & 0xF0) | (packets_n & 0x0F))
        valid = min(remaining, 25)
        logical.append(1 + valid)
        logical.append(button_index)
        src_base = 4 + q * 25
        for b in range(valid):
            idx = src_base + b
            logical.append(buffer[idx] if idx < len(buffer) else 0)
        remaining -= valid
        while len(logical) < 31:
            logical.append(0)
        chunks.append(set_checksum(logical))
    return chunks
