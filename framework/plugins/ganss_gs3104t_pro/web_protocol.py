"""GS3104T-PRO web-protocol (new firmware) packet layer.

Static-extracted from the official web driver (ganss.driveall.cn) JS.
See analysis/键盘网页驱动协议逆向报告.md. Transport: 32-byte output reports,
header [0xAA, cmd, len, addr_lo, addr_hi, ..., data at offset 8], 24B/chunk.

This channel is probed at runtime: if GET_DEVICE_INFO succeeds, the driver
enables media keys, macro, keymap readback and battery over this protocol.
The legacy EXE protocol remains the fallback for lighting/basic keymap.
"""
import struct
import time

HEADER_COUNT = 8
CHUNK = 32 - HEADER_COUNT  # 24 bytes of payload per packet


def command_error(Exception_T, msg):
    raise Exception_T(msg)


def build_packet(cmd, payload=b'', addr=0, last_flag=None):
    """One 32-byte output report per wn() of the web driver.
    payload: up to 24 bytes. last_flag: None → auto by 'no data preview' rule."""
    p = bytearray(32)
    p[0] = 0xAA
    p[1] = cmd & 0xFF
    p[2] = len(payload) & 0xFF
    p[3] = addr & 0xFF
    p[4] = (addr >> 8) & 0xFF
    if payload:
        p[8:8 + len(payload)] = payload
    if last_flag is not None and not payload:
        p[6] = 1 if last_flag else 0
    return bytes(p)


def chunked(cmd, data, addr_start=0):
    """Split data into 24B chunks with increasing addr."""
    packets = []
    n = (len(data) + CHUNK - 1) // CHUNK
    for i in range(n):
        chunk = data[i * CHUNK:(i + 1) * CHUNK]
        packets.append(build_packet(cmd, chunk, addr_start + i * CHUNK))
    return packets


# ---- Ge command constants (web driver enum) -------------------------------

GET_DEVICE_INFO = 16
GET_KEY = 18
GET_LED_EFFECT = 19
GET_MACRO = 21
GET_FN_KEY = 22
GET_DEFAULT_KEY_MATRIX = 31
SET_KEY = 34
SET_LED_EFFECT = 35
SET_MACRO = 37
SET_FN_KEY = 38
SET_KEYBOARD_CUSTOM_FUNCTION_ON = 48
SET_KEYBOARD_CUSTOM_FUNCTION_OFF = 49
SET_FACTORY_RESET = 15


# ---- key record encoders (new-protocol layout) -----------------------------

MODIFIERS = {'LCtrl': 1, 'LShift': 2, 'LAlt': 4, 'LWin': 8,
             'RCtrl': 16, 'RShift': 32, 'RAlt': 64, 'RWin': 128}

# Consumer Page usage table (from official web driver, identical to FLX3)
CONSUMER_KEYS = {
    '计算器': 402, '邮箱': 394, '多媒体': 387, '播放暂停': 205, '播放停止': 183,
    '上一曲': 182, '下一曲': 181, '音量+': 233, '音量-': 234, '静音': 226,
    '主页': 547, '刷新': 551, '前进': 549, '后退': 548, '收藏': 554, '搜索': 545,
}


def encode_record(target, macro_ids=None):
    """Encode a 4-byte keymap record (new protocol). Returns bytes(4).
    target: None/'default' → zeros; 'disabled' → mouse record no-op zeros;
            'media:音量+' → consumer key; 'macro:N' → macro reference;
            'KEYBOARD:usage' or 'usage' int → keyboard record;
            'LCtrl+C' combo → [2, mask, usage, 0]."""
    rec = bytearray(4)
    if target in (None, '', 'default'):
        return bytes(rec)
    if target == 'disabled':
        # official has no explicit disable: all-zero non-default record
        rec[0] = 14  # END page with zero params acts as no-op
        return bytes(rec)
    if target.startswith('media:'):
        name = target[6:]
        if name not in CONSUMER_KEYS:
            raise ValueError(f'未知多媒体键: {name}')
        usage = CONSUMER_KEYS[name]
        rec[0] = 3
        rec[1] = usage & 0xFF
        rec[2] = (usage >> 8) & 0xFF
        return bytes(rec)
    if target.startswith('macro:'):
        idx = int(target[6:])
        rec[0] = 6
        rec[1] = idx
        return bytes(rec)
    # keyboard key / combo — accept HID names like 'C' via the plugin keymap,
    # or raw usage ints like '0x04'/'4'
    mask, usage = 0, None
    for part in target.split('+'):
        part = part.strip()
        if part in MODIFIERS:
            mask |= MODIFIERS[part]
        else:
            try:
                usage = int(part, 0)
            except ValueError:
                usage = _lookup_usage(part)
    if usage is None:
        raise ValueError(f'{target} 缺少普通键')
    rec[0] = 2
    rec[1] = mask
    rec[2] = usage & 0xFF
    return bytes(rec)


_USAGE_ALIASES = {
    'a': 0x04, 'b': 0x05, 'c': 0x06, 'd': 0x07, 'e': 0x08, 'f': 0x09, 'g': 0x0A,
    'h': 0x0B, 'i': 0x0C, 'j': 0x0D, 'k': 0x0E, 'l': 0x0F, 'm': 0x10, 'n': 0x11,
    'o': 0x12, 'p': 0x13, 'q': 0x14, 'r': 0x15, 's': 0x16, 't': 0x17, 'u': 0x18,
    'v': 0x19, 'w': 0x1A, 'x': 0x1B, 'y': 0x1C, 'z': 0x1D,
    '1': 0x1E, '2': 0x1F, '3': 0x20, '4': 0x21, '5': 0x22, '6': 0x23,
    '7': 0x24, '8': 0x25, '9': 0x26, '0': 0x27,
    'enter': 0x28, 'esc': 0x29, 'backspace': 0x2A, 'tab': 0x2B, 'space': 0x2C,
    'minus': 0x2D, 'equal': 0x2E, 'leftbrace': 0x2F, 'rightbrace': 0x30,
    'backslash': 0x31, 'semicolon': 0x33, 'quote': 0x34, 'grave': 0x35,
    'comma': 0x36, 'dot': 0x37, 'slash': 0x38, 'capslock': 0x39,
    'f1': 0x3A, 'f2': 0x3B, 'f3': 0x3C, 'f4': 0x3D, 'f5': 0x3E, 'f6': 0x3F,
    'f7': 0x40, 'f8': 0x41, 'f9': 0x42, 'f10': 0x43, 'f11': 0x44, 'f12': 0x45,
    'left': 0x50, 'right': 0x4F, 'down': 0x51, 'up': 0x52,
}


def _lookup_usage(name):
    v = _USAGE_ALIASES.get(name.lower())
    if v is None:
        raise ValueError(f'未知按键: {name}')
    return v


# ---- macro serialization ----------------------------------------------------

ACTION_KEYBOARD = 3  # actionType from official recorder


def encode_macro_events(actions):
    """actions: [{isPress: bool, keyCode: int, delay_ms: int}] (keyboard type).
    Returns the macro data block: [u16 byte_count(=n*2), 0,0, event×4B]."""
    events = bytearray()
    for a in actions:
        delay = max(0, min(int(a.get('delay_ms', 0)), 65535))
        flags = (0x90 if a['isPress'] else 0x10)  # actionType 3 branch
        events += bytes([delay & 255, delay >> 8,
                         int(a['keyCode']) & 255, flags])
    block = bytearray(4)
    block[0] = (len(actions) * 2) & 0xFF
    block[1] = ((len(actions) * 2) >> 8) & 0xFF
    return bytes(block) + bytes(events)


def encode_macro_table(macros):
    """macros: {slot(int 0..99): data_block(bytes)}. Returns 400B pointer table
    + concatenated data blocks, ready for chunked(SET_MACRO, ...)."""
    table = bytearray(400)
    blocks = bytearray()
    offset = 400
    for slot in sorted(macros):
        data = macros[slot]
        struct.pack_into('<I', table, slot * 4, offset)
        blocks += data
        offset += len(data)
    return bytes(table), bytes(blocks)


# ---- lighting (16B block, SET_LED_EFFECT=35) --------------------------------

def encode_light_block(mode, r, g, b, brightness, speed, direction=0,
                       color_mode=0, effect_type=0, sec=(0, 0, 0)):
    p = bytearray(16)
    p[0] = mode & 0xFF
    p[1], p[2], p[3] = r & 0xFF, g & 0xFF, b & 0xFF
    p[4] = 255
    p[5], p[6], p[7] = sec[0], sec[1], sec[2]
    p[8] = color_mode
    p[9] = brightness & 0xFF
    p[10] = speed & 0xFF
    p[11] = direction & 0xFF
    p[12] = effect_type
    p[14], p[15] = 0xAA, 0x55
    return bytes(p)


# ---- device info -------------------------------------------------------------

def parse_device_info(payload48):
    d = payload48
    return {
        'vid': d[4] | d[5] << 8,
        'pid': d[6] | d[7] << 8,
        'battery_level': d[17],
        'charge_status': d[18],
        'current_profile': d[19],
        'frame_version': d[30],
        'firmware_status': d[32],
    }


class WebProtocolSession:
    """Stateful wrapper running the AA-header protocol over a HidTransport
    bound to the keyboard's 64B feature channel (interface 4) — the only
    endpoint observed answering AA packets on real hardware.

    The keyboard sleeps when idle; probing must be preceded by a wake
    attempt (any old-protocol write) and retried after user keystrokes.
    When probe() returns None the driver falls back to the legacy EXE
    protocol and hides media/macro/readback features."""

    def __init__(self, transport):
        self.t = transport

    def _send_expect(self, cmd, payload=b'', addr=0, expect_cmd=None, timeout_ms=500):
        pkt = build_packet(cmd, payload, addr)
        self.t.write_output(0, pkt)
        expect = expect_cmd if expect_cmd is not None else cmd
        deadline = time.monotonic() + timeout_ms / 1000
        while time.monotonic() < deadline:
            got = self.t.poll_input(64, timeout_ms=max(1, int((deadline - time.monotonic()) * 1000)))
            if got is None:
                break
            _rid, resp = got
            # Web firmware replies with 0x55 header + echoed cmd.
            # Observed legacy firmware answers AA packets with 0F 01 01 11 —
            # treat that as "protocol unsupported".
            if resp and resp[0] == 0x0F:
                return 'unsupported'
            if len(resp) >= 2 and resp[0] == 0x55 and resp[1] == expect:
                return resp
        return None

    def probe(self):
        """GET_DEVICE_INFO round-trip. Returns parsed info dict,
        'unsupported' (legacy firmware) or None (device asleep/no answer)."""
        resp = self._send_expect(GET_DEVICE_INFO, b'\x00' * 24, expect_cmd=GET_DEVICE_INFO)
        if resp == 'unsupported':
            return 'unsupported'
        if resp and len(resp) >= 40:
            return parse_device_info(resp[8:56] if len(resp) >= 56 else resp[8:])
        return None

    def read_keymap(self, fn_layer=False):
        cmd = GET_FN_KEY if fn_layer else GET_KEY
        chunks = []
        addr = 0
        total = 512
        while addr < total:
            resp = self._send_expect(cmd, struct.pack('<H', min(CHUNK, total - addr)) + b'\x00' * 22,
                                     addr=addr)
            if not resp or resp == 'unsupported':
                return None
            chunks.append(resp[8:])
            addr += CHUNK
        return b''.join(chunks)[:total]

    def write_keymap(self, table512, fn_layer=False):
        cmd = SET_FN_KEY if fn_layer else SET_KEY
        for pkt in chunked(cmd, table512):
            self.t.write_output(0, pkt)
            time.sleep(0.02)
        return True

    def write_macro(self, macros):
        table, blocks = encode_macro_table(macros)
        for pkt in chunked(SET_MACRO, table, addr_start=0):
            self.t.write_output(0, pkt)
            time.sleep(0.02)
        for pkt in chunked(SET_MACRO, blocks, addr_start=400):
            self.t.write_output(0, pkt)
            time.sleep(0.02)
        return True

    def set_custom_function(self, on):
        cmd = SET_KEYBOARD_CUSTOM_FUNCTION_ON if on else SET_KEYBOARD_CUSTOM_FUNCTION_OFF
        return self._send_expect(cmd, b'\x00' * 24) is not None
