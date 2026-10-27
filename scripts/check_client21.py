import json,struct
from pathlib import Path
def signed(v,b):return v-(1<<b) if v&(1<<(b-1)) else v
rows=json.loads(Path(__file__).with_name('client21-bridges.json').read_text())
regions=[]
for r in rows:
    code=bytes.fromhex(r['code']);pc=r['bridge'];adrs=[];calls=[]
    for i,(w,) in enumerate(struct.iter_unpack('<I',code)):
        if w&0x9f000000==0x10000000:
            value=((w>>29)&3)|(((w>>5)&0x7ffff)<<2);adrs.append((w&31,pc+i*4+signed(value,21)))
        if w>>26==0x25:calls.append(pc+i*4+signed(w&0x3ffffff,26)*4)
    assert (1,r['symbol']) in adrs and calls==[0x12556d8]
    if r.get('args') is not None and r['kind']=='wrapper':assert (r['args'],r['trampoline']) in adrs
    for start,end,kind in [(r['bridge'],r['bridge']+len(code),'bridge'),(r['symbol'],r['symbol']+len(r['export'])+1,'symbol'),(r['trampoline'],r['trampoline']+8,'trampoline')]:
        assert 0x1100<=start<end<=0x3f00
        for otherStart,otherEnd,other in regions:assert end<=otherStart or start>=otherEnd,(r['name'],kind,other)
        regions.append((start,end,r['name']+' '+kind))
# Prior hooks and their manifests must survive.
for start,end in [(0x2000,0x2080),(0x2100,0x2120),(0x2200,0x2214),(0x2300,0x2338),(0x2500,0x2650),(0x2d00,0x2d20),(0x2f00,0x2f18)]:
    assert all(end<=a or start>=b for a,b,_ in regions)
assert len(rows)==13
print('All 13 bridge/symbol/trampoline allocations and prior manifests passed')
