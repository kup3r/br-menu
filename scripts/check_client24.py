"""Validate new segment metadata, adapter references and optional patched bytes."""
import json,struct,sys
from pathlib import Path
from patch_client24 import ROW,branch
r=ROW;code=bytes.fromhex(r['code'])
assert r['entry']>=r['vmaddr']+24 and r['entry']+len(code)<=r['symbol']
assert r['symbol']+len(r['export'])+1<r['vmaddr']+r['size']
assert branch(r['callsite'],r['entry'],True)
refs=[]
for i in range(0,len(code),4):
    w=struct.unpack_from('<I',code,i)[0];pc=r['entry']+i
    if w&0x9f000000==0x10000000:
        delta=((w>>29)&3)|(((w>>5)&0x7ffff)<<2);delta=delta-(1<<21) if delta&(1<<20) else delta;refs.append(pc+delta)
assert refs==[r['symbol']]
if len(sys.argv)>1:
    b=Path(sys.argv[1]).read_bytes();count,size=struct.unpack_from('<II',b,16);cursor=32;segments=[];chain=None
    for _ in range(count):
        cmd,n=struct.unpack_from('<II',b,cursor)
        if cmd==0x19:
            name=b[cursor+8:cursor+24].split(b'\0')[0].decode();vm,vs,fo,fs=struct.unpack_from('<QQQQ',b,cursor+24);segments.append((name,vm,vs,fo,fs))
        if cmd==0x80000034:chain=struct.unpack_from('<II',b,cursor+8)
        if cmd in (0x80000034,0x80000033,0x26,0x29,0x1d):
            off,length=struct.unpack_from('<II',b,cursor+8);assert off+length<=len(b)
        cursor+=n
    assert cursor==32+size<0x1100
    native=next(s for s in segments if s[0]=='__REACT24');link=next(s for s in segments if s[0]=='__LINKEDIT')
    assert native[1]==r['vmaddr'] and native[3]==r['fileoff'] and native[4]==r['size']
    assert native[1]+native[2]==link[1] and native[3]+native[4]==link[3]
    assert link[3]+link[4]==len(b)
    assert b[r['callsite']:r['callsite']+4]==branch(r['callsite'],r['entry'],True)
    assert b[native[3]+r['entry']-native[1]:native[3]+r['entry']-native[1]+len(code)]==code
    h=struct.unpack_from('<7I',b,chain[0]);start=chain[0]+h[1];cnt=struct.unpack_from('<I',b,start)[0]
    assert cnt==len(segments)==5
    offsets=struct.unpack_from('<'+'I'*cnt,b,start+4);assert offsets[-2:]==(0,0)
    for i,off in enumerate(offsets):
        if not off:continue
        segmentOffset=struct.unpack_from('<Q',b,start+off+8)[0];assert segmentOffset==segments[i][1]
print('Water segment bounds, symbol ADR, chained starts and prior header padding passed')
