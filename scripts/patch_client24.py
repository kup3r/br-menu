"""Add one isolated, default-pass water-physics gate to a new client copy.

Existing code/data VAs stay fixed. A page is inserted before __LINKEDIT; the
chained-starts table gains an empty segment and all affected file offsets move.
"""
import argparse,hashlib,json,struct
from pathlib import Path
ROW=json.loads(Path(__file__).with_name('client24-water.json').read_text())
SOURCE_SHA='e38a96a8430e34bb82f85d930110979649a5c3913785f42206bbeef0ddb3bbbc'
def branch(pc,target,link=False):
    delta=target-pc
    if delta%4 or not -(1<<27)<=delta<(1<<27):raise ValueError('Branch out of range')
    return struct.pack('<I',(0x94000000 if link else 0x14000000)|((delta//4)&0x3ffffff))
def patch(source):
    if hashlib.sha256(source).hexdigest()!=SOURCE_SHA:raise ValueError('Expected the exact validated v21-v23 client')
    b=bytearray(source);count,size=struct.unpack_from('<II',b,16);cursor=32;commands=[]
    for _ in range(count):
        cmd,n=struct.unpack_from('<II',b,cursor);commands.append(bytearray(b[cursor:cursor+n]));cursor+=n
    if cursor!=32+size or any(b[cursor:cursor+72]) or cursor+72>0x1100:raise ValueError('No verified header padding')
    oldSegments=[c for c in commands if struct.unpack_from('<I',c)[0]==0x19]
    link=next(c for c in oldSegments if c[8:24].split(b'\0')[0]==b'__LINKEDIT')
    vm,vs,fo,fs=struct.unpack_from('<QQQQ',link,24);page=ROW['size']
    if (vm,fo)!=(ROW['vmaddr'],ROW['fileoff']) or fs+16>vs:raise ValueError('Unexpected linkedit layout')
    if source[ROW['callsite']:ROW['callsite']+4]!=branch(ROW['callsite'],ROW['original'],True):raise ValueError('Water call mismatch')
    chain=next(c for c in commands if struct.unpack_from('<I',c)[0]==0x80000034)
    chainoff,chainsize=struct.unpack_from('<II',chain,8);payload=bytearray(source[chainoff:chainoff+chainsize])
    header=list(struct.unpack_from('<7I',payload));starts=header[1];segments=struct.unpack_from('<I',payload,starts)[0]
    offsets=list(struct.unpack_from('<'+'I'*segments,payload,starts+4))
    if segments!=len(oldSegments) or segments!=4 or offsets[-1]!=0:raise ValueError('Unexpected chained segment table')
    insertion=starts+4+segments*4;absoluteInsertion=chainoff+insertion
    payload[insertion:insertion]=bytes(16)
    struct.pack_into('<I',payload,starts,segments+1)
    for i,offset in enumerate(offsets):struct.pack_into('<I',payload,starts+4+i*4,offset+16 if offset else 0)
    # The old final zero now describes __REACT24; the appended zero describes __LINKEDIT.
    for index in (2,3):
        if header[index]>=insertion:header[index]+=16
    struct.pack_into('<7I',payload,0,*header)
    def translated(offset):return offset+(page if offset>=fo else 0)+(16 if offset>=absoluteInsertion else 0) if offset else 0
    result=bytearray(source[:fo])+bytearray(page)+bytearray(source[fo:absoluteInsertion])+bytearray(16)+bytearray(source[absoluteInsertion:])
    result[translated(chainoff):translated(chainoff)+len(payload)]=payload
    rebuilt=[]
    for c in commands:
        cmd=struct.unpack_from('<I',c)[0]
        if cmd==0x19:
            name=c[8:24].split(b'\0')[0]
            if name==b'__LINKEDIT':
                newSegment=struct.pack('<II16sQQQQiiII',0x19,72,b'__REACT24\0',vm,page,fo,page,5,5,0,0)
                rebuilt.append(newSegment);struct.pack_into('<Q',c,24,vm+page);struct.pack_into('<Q',c,48,fs+16)
            old=struct.unpack_from('<Q',c,40)[0];struct.pack_into('<Q',c,40,translated(old))
            for i in range(struct.unpack_from('<I',c,64)[0]):
                q=72+i*80;off=struct.unpack_from('<I',c,q+48)[0];struct.pack_into('<I',c,q+48,translated(off))
                rel=struct.unpack_from('<I',c,q+56)[0];struct.pack_into('<I',c,q+56,translated(rel))
        elif cmd==2:
            for q in (8,16):struct.pack_into('<I',c,q,translated(struct.unpack_from('<I',c,q)[0]))
        elif cmd==0xb:
            for q in (32,40,48,56,64,72):struct.pack_into('<I',c,q,translated(struct.unpack_from('<I',c,q)[0]))
        elif cmd in (0x22,0x80000022):
            for q in (8,16,24,32,40):struct.pack_into('<I',c,q,translated(struct.unpack_from('<I',c,q)[0]))
        elif cmd in (0x1d,0x1e,0x26,0x29,0x2b,0x2e,0x80000033,0x80000034,0x16):
            struct.pack_into('<I',c,8,translated(struct.unpack_from('<I',c,8)[0]))
            if cmd==0x80000034:struct.pack_into('<I',c,12,chainsize+16)
        elif cmd==0x31:
            old=struct.unpack_from('<Q',c,24)[0];struct.pack_into('<Q',c,24,translated(old))
        rebuilt.append(c)
    rebuiltBytes=b''.join(rebuilt);result[32:32+len(rebuiltBytes)]=rebuiltBytes
    struct.pack_into('<II',result,16,count+1,size+72)
    code=bytes.fromhex(ROW['code']);symbol=ROW['export'].encode()+b'\0'
    codeoff=fo+ROW['entry']-vm;symoff=fo+ROW['symbol']-vm
    result[fo:fo+24]=struct.pack('<8sIIII',b'REACT24\0',1,ROW['callsite'],ROW['entry'],ROW['original'])
    result[codeoff:codeoff+len(code)]=code;result[symoff:symoff+len(symbol)]=symbol
    result[ROW['callsite']:ROW['callsite']+4]=branch(ROW['callsite'],ROW['entry'],True)
    return bytes(result)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    if a.output.exists() or a.source.resolve()==a.output.resolve():raise ValueError('Choose a new output')
    b=patch(a.source.read_bytes());a.output.write_bytes(b);print(json.dumps({'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}))
