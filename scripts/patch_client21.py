"""Upgrade a copy of the exact v20 client. Source is never overwritten."""
from pathlib import Path
import hashlib,json,struct,argparse
from patch_client20 import branch,relocate
INPUT_SHA='8b54630a0153cd13df73e33cb92fd24365425f6f8dc72f2b9d97898126d5e96b'
def upgrade(data):
    if hashlib.sha256(data).hexdigest()!=INPUT_SHA:raise ValueError('Unverified v20 client SHA256')
    rows=json.loads(Path(__file__).with_name('client21-bridges.json').read_text())
    for r in rows[:9]:
        if data[r['entry']:r['entry']+4]!=branch(r['entry'],r['bridge']):raise ValueError('Invalid existing entry')
    for r in rows[9:]:
        if data[r['entry']:r['entry']+16]!=bytes.fromhex(r['original']):raise ValueError('Unexpected '+r['name']+' prologue')
        for start,end in ((r['bridge'],r['bridge']+len(bytes.fromhex(r['code']))),(r['trampoline'],r['trampoline']+8),(r['symbol'],r['symbol']+64)):
            if any(data[start:end]):raise ValueError('Occupied reserved padding')
    out=bytearray(data)
    for r in [rows[3]]+rows[9:]:
        code=bytes.fromhex(r['code']);symbol=r['export'].encode()+b'\0'
        if len(symbol)>64:raise ValueError('Symbol allocation')
        out[r['bridge']:r['bridge']+len(code)]=code
        out[r['symbol']:r['symbol']+64]=symbol+bytes(64-len(symbol))
        if r in rows[9:]:
            word=struct.unpack_from('<I',data,r['entry'])[0]
            out[r['trampoline']:r['trampoline']+8]=struct.pack('<I',relocate(word,r['entry'],r['trampoline']))+branch(r['trampoline']+4,r['entry']+4)
            out[r['entry']:r['entry']+4]=branch(r['entry'],r['bridge'])
    manifest=b'REACT21\0'+struct.pack('<II',1,len(rows))+b''.join(struct.pack('<4I',*(r[k] for k in ('entry','bridge','trampoline','symbol'))) for r in rows)
    assert len(manifest)<=256
    out[0x3f00:0x4000]=manifest+bytes(256-len(manifest))
    return bytes(out)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('destination',type=Path);a=p.parse_args()
    if a.source.resolve()==a.destination.resolve() or a.destination.exists():raise SystemExit('Choose a fresh output path')
    a.destination.write_bytes(upgrade(a.source.read_bytes()));print(hashlib.sha256(a.destination.read_bytes()).hexdigest())
