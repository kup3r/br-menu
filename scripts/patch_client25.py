"""Observe the server-client-message render call; preserve original delivery."""
import hashlib,json,struct,argparse
from pathlib import Path
from patch_client24 import branch
ROW=json.loads(Path(__file__).with_name('client25-event.json').read_text())
SOURCE_SHA='dcfb41d1fa9ce1e79b4946df7e8cbb30360060ef0806b4bb41264256d348b121'
def patch(source):
 if hashlib.sha256(source).hexdigest()!=SOURCE_SHA:raise ValueError('Expected validated v24 client')
 r=ROW;b=bytearray(source);vm=0x353c000;fo=0x1a6c000
 assert b[r['callsite']:r['callsite']+4]==branch(r['callsite'],r['original'],True)
 code=bytes.fromhex(r['code']);co=fo+r['entry']-vm;so=fo+r['symbol']-vm
 assert not any(b[co:co+len(code)]) and not any(b[so:so+64]) and not any(b[fo+0x40:fo+0x60])
 assert r['entry']+len(code)<r['symbol'] and r['symbol']+64<vm+0x4000
 b[co:co+len(code)]=code;name=r['export'].encode()+b'\0';b[so:so+len(name)]=name
 b[fo+0x40:fo+0x50]=struct.pack('<8sII',b'REACT25\0',1,r['callsite'])
 b[r['callsite']:r['callsite']+4]=branch(r['callsite'],r['entry'],True)
 return bytes(b)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
 if a.output.exists() or a.output.resolve()==a.source.resolve():raise ValueError('Choose new output')
 a.output.write_bytes(patch(a.source.read_bytes()))
