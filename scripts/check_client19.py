import json,struct
from pathlib import Path
def signed(value,bits):return value-(1<<bits) if value&(1<<(bits-1)) else value
rows=json.loads(Path(__file__).with_name('client19-bridges.json').read_text())
for r in rows:
    code=bytes.fromhex(r['code']);base=r['bridge']
    assert len(code)<0x300 and code[:4]==bytes.fromhex('ff430cd1')
    word=struct.unpack_from('<I',code,0x90)[0]
    assert word&0x9f00001f==0x10000001
    imm=((word>>29)&3)|(((word>>5)&0x7ffff)<<2)
    assert base+0x90+signed(imm,21)==r['symbol']
    word=struct.unpack_from('<I',code,0x94)[0]
    assert word>>26==0x25
    assert base+0x94+signed(word&0x3ffffff,26)*4==0x12556d8
    word=struct.unpack_from('<I',code,len(code)-4)[0]
    assert word>>26==5
    assert base+len(code)-4+signed(word&0x3ffffff,26)*4==r['trampoline']
    assert len(bytes.fromhex(r['original']))==16
    assert r['trampoline']>=0x3c00 and r['trampoline']+8<=0x3d00
    assert r['symbol']>=0x3d00 and r['symbol']+len(r['export'])+1<=0x3f00
print('Additional bridge ADR, BL, B targets and allocations passed')
