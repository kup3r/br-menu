"""Upgrade only the independently verified v18 client copy. Never patch input in place."""
import hashlib,json,struct,argparse
from pathlib import Path
INPUT_SHA='98b91192d8a171e61af32e4b9faf0b64296c3d8c3e3758dc0d0e8be4750b3e81'
MANIFEST=0x3f00
def branch(pc,target):
    d=target-pc
    if d%4 or not -(1<<27)<=d<(1<<27):raise ValueError('Branch range')
    return struct.pack('<I',0x14000000|((d//4)&0x3ffffff))
def relocate(word,source,target):
    if word&0x9f000000==0x90000000:
        imm=((word>>29)&3)|(((word>>5)&0x7ffff)<<2)
        if imm&(1<<20):imm-=1<<21
        page=(source&~4095)+(imm<<12)
        pages=(page-(target&~4095))>>12
        if not -(1<<20)<=pages<(1<<20):raise ValueError('ADRP range')
        return 0x90000000|(word&31)|((pages&3)<<29)|(((pages>>2)&0x7ffff)<<5)
    if word&0x1f000000==0x10000000 or word&0x7c000000==0x14000000 or word&0x3b000000==0x18000000:
        raise ValueError('Unexpected PC-relative trampoline instruction')
    return word
def upgrade(data):
    if hashlib.sha256(data).hexdigest()!=INPUT_SHA:raise ValueError('Unverified client SHA256')
    if any(data[0x3000:0x4000]):raise ValueError('Reserved padding is occupied')
    rows=json.loads(Path(__file__).with_name('client19-bridges.json').read_text())
    out=bytearray(data);records=[]
    for r in rows:
        entry,bridge,tramp,symbol=(r[x] for x in ['entry','bridge','trampoline','symbol'])
        original=bytes.fromhex(r['original'])
        if data[entry:entry+16]!=original:raise ValueError('Unexpected '+r['name']+' entry')
        code=bytes.fromhex(r['code']);name=r['export'].encode()+b'\0'
        if len(code)>0x300 or len(name)>64:raise ValueError('Bridge allocation')
        out[bridge:bridge+len(code)]=code
        out[symbol:symbol+len(name)]=name
        first=relocate(struct.unpack_from('<I',data,entry)[0],entry,tramp)
        out[tramp:tramp+8]=struct.pack('<I',first)+branch(tramp+4,entry+4)
        out[entry:entry+4]=branch(entry,bridge)
        records.append(struct.pack('<4I',entry,bridge,tramp,symbol))
    manifest=b'REACT19\0'+struct.pack('<II',1,len(records))+b''.join(records)
    out[MANIFEST:MANIFEST+len(manifest)]=manifest
    return bytes(out)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('destination',type=Path);a=p.parse_args()
    if a.source.resolve()==a.destination.resolve() or a.destination.exists():raise SystemExit('Choose a fresh output path')
    a.destination.write_bytes(upgrade(a.source.read_bytes()))
    print(hashlib.sha256(a.destination.read_bytes()).hexdigest())
