"""GS3104T-PRO protocol golden-packet tests (aligns with FLX3's 38 tests)."""
import sys, json
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from framework.plugins.ganss_gs3104t_pro import protocol as P

failures = []
def check(name, cond, detail=''):
    if cond: print(f'  ok  {name}')
    else:
        failures.append(name); print(f'FAIL  {name}  {detail}')

# feature wrapper: report-ID 0 + 64B payload
f = P.feature(bytes(range(64)))
check('feature 65B with leading 0', len(f) == 65 and f[0] == 0)

# command builder: [04, code, ..., arg@8]
c = P.command(0x11, 9)
check('command cmd=04', c[1] == 4 and c[2] == 0x11)
check('command arg@8', c[9] == 9)
check('command length 65', len(c) == 65)

# short packet checksum
sp = P.short_packet(bytes([0, 3, 4, 26] + [0]*29))  # noqa
check('short 33B', len(sp) == 33)
check('short checksum = low8 sum of first 32', sp[32] == (sum(sp[:32]) & 255))

# light plan (wireless): [05,10,00,mode,rgb...,bri|spd,AA55]
plan = P.light_plan(connection='wireless', mode=11, color='FF6A00', brightness=4, speed=3)
check('light wireless 1 step', len(plan) == 1 and plan[0].channel == 'short')
d = plan[0].data
check('light mode=0x0b', d[4] == 0x0b)
check('light rgb @5..7', (d[5], d[6], d[7]) == (0xFF, 0x6A, 0x00))
check('light AA55 tail', (d[18], d[19]) == (0xAA, 0x55))
check('light checksum', d[32] == (sum(d[:32]) & 255))

# light plan (wired): 5 steps with feature channel
plan = P.light_plan(connection='usb', mode=1, color='FF0000')
check('light wired 5 steps', len(plan) == 5 and all(s.channel == 'feature' for s in plan))
check('light wired prep 04 18', plan[0].data[1:3] == bytes([4, 0x18]))

# single key plan wireless: [03/0D, len, key_index, record]
plan = P.keymap_single_plan('Q', 'W', layer='normal', connection='wireless')
d = plan[0].data
q_idx = int(P.resolve_key('Q')['key_index'])
check('single-key cmd=03', d[1] == 3)
check('single-key idx', d[3] == q_idx)
check('single-key record type=2', d[4] == 2)

# combo record: LCtrl+C → mask=1, usage=6
plan = P.keymap_single_plan('Q', 'LCtrl+C', layer='normal', connection='wireless')
d = plan[0].data
check('combo record [2,1,6,0]', tuple(d[4:8]) == (2, 1, 6, 0), tuple(d[4:8]))

# media record via driver._legacy_record: [3, LE16]
sys.path.insert(0, '.')
from framework.plugins.ganss_gs3104t_pro.driver import _legacy_record
rec = _legacy_record('media:音量+')
check('media record [3,e9,00,00]', rec == bytes([3, 0xE9, 0x00, 0x00]), rec.hex(' '))
rec = _legacy_record('disabled')
check('disabled record [1,0,0,0]', rec == bytes([1, 0, 0, 0]))
rec = _legacy_record('macro:2')
check('macro record [6,2,0,0]', rec == bytes([6, 2, 0, 0]))
rec = _legacy_record('LCtrl+C')
check('combo via legacy [2,1,6,0]', rec == bytes([2, 1, 6, 0]))
rec = _legacy_record('Win_L')  # official name → usage 0xE3
check('Win_L alias usage 0xE3', rec == bytes([2, 0, 0xE3, 0]), rec.hex(' '))

# keymap plan wired: 9×64B blocks of 576B table
plan = P.keymap_plan({'version':1,'layer':'normal','mappings':{'A':'B'}}, 'usb')
check('keymap wired 13 steps', len(plan) == 2 + 9 + 2, len(plan))
check('keymap layer select 04 11', plan[1].data[1:3] == bytes([4, 0x11]))

# keymap plan wireless: 21 blocks of 28B
plan = P.keymap_plan({'version':1,'layer':'normal','mappings':{'A':'B'}}, 'wireless')
check('keymap wireless 21 steps', len(plan) == 21)
check('last block len=16', plan[-1].data[2] == 16)

# Fn layer select 04 27
plan = P.keymap_plan({'version':1,'layer':'fn','mappings':{}}, 'usb')
check('fn layer 04 27', plan[1].data[1:3] == bytes([4, 0x27]))

# Fn reserved
try:
    P.parse_profile({'version':1,'layer':'normal','mappings':{'Fn':'B'}})
    check('Fn reserved reject', False)
except Exception:
    check('Fn reserved reject', True)

print()
if failures:
    print('FAILURES:', failures); sys.exit(1)
print('ALL KB PROTOCOL GOLDEN TESTS PASSED')
