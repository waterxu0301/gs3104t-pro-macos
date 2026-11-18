"""FLX3 protocol golden-packet tests (offsets per insert-at-idx3 layout)."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from framework.plugins.ganss_flx3 import protocol as P

failures = []
def check(name, cond, detail=""):
    if cond: print(f"  ok  {name}")
    else:
        failures.append(name); print(f"FAIL  {name}  {detail}")

# checksum: logical idx3 excluded from sum, shifted to idx4
buf = P.set_checksum([4,1,1,17]+[0]*27)
check("len 32", len(buf)==32)
check("cmd/seq/sub at 0-2", (buf[0],buf[1],buf[2])==(4,1,1))
check("sum at idx3", buf[3]==(6+4+1+1)&0xFF, hex(buf[3]))
check("rate shifted to idx4", buf[4]==17)

# keymap: rec_i at buf[4+(i-1)*3]
buttons = {1:"mouse:左键",2:"mouse:右键",3:"mouse:中键",4:"mouse:前进",5:"mouse:后退",6:"dpi_cycle"}
buf = P.encode_keymap_packet(buttons, seq=5)
check("keymap 32B", len(buf)==32)
check("cmd=1 seq=5 sub=1", (buf[0],buf[1],buf[2])==(1,5,1))
def rec(i): return tuple(buf[4+(i-1)*3:4+i*3])
check("slot1=左键", rec(1)==(16,1,0), rec(1))
check("slot2=右键", rec(2)==(16,2,0), rec(2))
check("slot3=中键", rec(3)==(16,4,0), rec(3))
check("slot4(idx3)=btn5 后退", rec(4)==(16,8,0), rec(4))
check("slot5(idx4)=btn4 前进", rec(5)==(16,16,0), rec(5))
check("slot6=btn6 dpi_cycle", rec(6)==(64,1,0), rec(6))
check("slot7-9 unconfigured", all(rec(i)==(255,255,255) for i in (7,8,9)))

buf2 = P.encode_keymap_packet({4:"LCtrl+C"}, seq=1)
check("combo btn4 at slot idx4", tuple(buf2[16:19])==(112,1,0x06), tuple(buf2[16:19]))
buf3 = P.encode_keymap_packet({5:"media:播放暂停"}, seq=1)
check("media 0x00CD LE at slot idx3", tuple(buf3[13:16])==(128,205,0), tuple(buf3[13:16]))

# DPI: buf[2]=axis, buf[4]=lvl, buf[5]=mask, dpi pairs from buf[6]
buf = P.encode_dpi_packet("x",2,0x3F,[400,800,1600,3200,6400],149,9)
check("dpi axis=2", buf[2]==2)
check("dpi lvl=2 mask=0x3F", (buf[4],buf[5])==(2,0x3F))
check("400→7 LE", (buf[6],buf[7])==(7,0), (buf[6],buf[7]))
check("800→15", (buf[8],buf[9])==(15,0))
check("1600→31", (buf[10],buf[11])==(31,0))
check("6400→127", (buf[14],buf[15])==(127,0), (buf[14],buf[15]))
b2 = P.encode_dpi_packet("x",0,0xFF,[30000],80,1)
check("3950 30000→599", (b2[6],b2[7])==(599&255,599>>8), (b2[6],b2[7]))
b3 = P.encode_dpi_packet("x",0,0xFF,[12000],17,1)
check("3311 12000→119", (b3[6],b3[7])==(119,0))

buf = P.encode_polling_packet(17, seq=2)
check("polling rate at idx4", buf[4]==17)
buf = P.encode_power_packet(15, True, False, seq=3)
check("power 15/1/0", (buf[4],buf[5],buf[6])==(15,1,0))
buf = P.encode_sensor_packet(True,False,True, seq=4)
check("sensor 1/0/1", (buf[4],buf[5],buf[6])==(1,0,1))
buf = P.encode_light_packet(3,"#409EFF",4,3,seq=5)
check("light mode/brightness|speed/RGB", buf[5]==3 and buf[6]==(4<<4)|3 and (buf[8],buf[9],buf[10])==(0x40,0x9E,0xFF))
buf = P.encode_reset_packet(seq=6)
check("reset", buf[0]==15 and buf[4]==255)

# macro events (write-side flags: press 0xB0 / release 0x30 for actionType 3)
events=[{"type":"key","isPress":True,"keyCode":4,"delay_ms":10,"index":0},
        {"type":"key","isPress":False,"keyCode":4,"delay_ms":5,"index":1}]
b = P.encode_macro_events(events)
check("head [9,144,0,2]", b[:4]==[9,144,0,2], b[:4])
# ev1 press, next delay=5 → b1=0xB0|0, b2=5, b3=4
check("ev1 press [B0,10,4]", b[4:7]==[0xB0,10,4], b[4:7])
# ev2 release, no next → b1=0x30, b2=0, b3=4
check("ev2 release [30,5,4]", b[7:10]==[0x30,5,4], b[7:10])
# actionType 1/2 → 0x90/0x10
b2 = P.encode_macro_events([{"type":"key","isPress":True,"keyCode":240,"delay_ms":20,"index":0,"actionType":1}])
check("mouse F0 actionType1 [90,20,1] (240&7->1 per official)", b2[4:7]==[0x90,20,1], b2[4:7])

chunks = P.encode_macro_chunks(list(b), button_index=4)
check("1 chunk", len(chunks)==1)
c = chunks[0]
# chunk logical [16,seq,count,len,btn,...]: buf[2]=count, buf[4]=len(7), buf[5]=btn
check("chunk header 16/1/count01/len7/btn4", (c[0],c[1],c[2],c[4],c[5])==(16,1,0x01,7,4), c[:7])
big = list(b)+[0]*30
check("2 chunks", len(P.encode_macro_chunks(big,5))==2)
buf = P.encode_macro_erase(seq=1)
check("erase", buf[0]==17 and buf[4]==255 and buf[10]==0)

state = P.parse_input_report([4,0,2,1,90,1,3,0,2,149])
check("input battery/sensor/maxRate", state["batteryLevel"]==90 and state["sensorType"]==149 and state["maxReportRate"]==2)

print()
if failures:
    print("FAILURES:", failures); sys.exit(1)
print("ALL FLX3 GOLDEN TESTS PASSED")
