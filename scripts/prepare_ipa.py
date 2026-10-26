#!/usr/bin/env python3
"""Create a NEW unsigned v17 IPA with matching bridges + compiled menu dylib."""
import argparse,struct,zipfile,json,hashlib
from pathlib import Path
from patch_client import patch,CLIENT
APP='Payload/BrBase.app/'
LOAD_NAME='@executable_path/Frameworks/BRMenuInject.dylib'
def load_menu(data):
    if struct.unpack_from('<I',data)[0]!=0xfeedfacf:raise ValueError('Expected 64-bit Mach-O executable')
    count,size=struct.unpack_from('<II',data,16);cursor=32;first=len(data)
    for _ in range(count):
        cmd,n=struct.unpack_from('<II',data,cursor)
        if cmd==0xc:
            off=struct.unpack_from('<I',data,cursor+8)[0]
            name=data[cursor+off:cursor+n].split(b'\0')[0].decode()
            if 'BRMenuInject' in name:raise ValueError('Input IPA already contains a menu; use the original input')
        if cmd==0x19:
            for j in range(struct.unpack_from('<I',data,cursor+64)[0]):
                p=cursor+72+80*j;offset=struct.unpack_from('<I',data,p+48)[0]
                if offset:first=min(first,offset)
        cursor+=n
    assert cursor==32+size
    path=LOAD_NAME.encode()+b'\0';command_size=(24+len(path)+7)&~7
    if cursor+command_size>first or any(data[cursor:cursor+command_size]):raise ValueError('No verified zero header padding for the dylib command')
    command=struct.pack('<6I',0xc,command_size,24,0,0,0)+path
    command+=b'\0'*(command_size-len(command));out=bytearray(data)
    out[cursor:cursor+command_size]=command;struct.pack_into('<II',out,16,count+1,size+command_size)
    return bytes(out)
def package(source,dylib,destination):
    if destination.exists() or source.resolve()==destination.resolve():raise ValueError('Choose a new output; existing files and source are never overwritten')
    menu=dylib.read_bytes()
    if struct.unpack_from('<I',menu)[0]!=0xfeedfacf or struct.unpack_from('<I',menu,12)[0]!=6:raise ValueError('Expected thin Mach-O dylib')
    if b'BRMenuQueueHook15\0' not in menu or b'BRMenuAspectHook17\0' not in menu:raise ValueError('This is not the matching v17 dylib')
    with zipfile.ZipFile(source) as zin:
        client=patch(zin.read(CLIENT));main=load_menu(zin.read(APP+'BrBase'))
        with zipfile.ZipFile(destination,'w',compresslevel=1,allowZip64=True) as zout:
            for item in zin.infolist():
                data=client if item.filename==CLIENT else main if item.filename==APP+'BrBase' else zin.read(item)
                zout.writestr(item,data,compresslevel=1)
            zout.writestr(APP+'Frameworks/BRMenuInject.dylib',menu,compress_type=zipfile.ZIP_DEFLATED,compresslevel=1)
    return {'output':str(destination),'menu_already_embedded':True,'requires_full_resigning':True,'sha256':hashlib.file_digest(open(destination,'rb'),'sha256').hexdigest()}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('dylib',type=Path);p.add_argument('destination',type=Path);a=p.parse_args();print(json.dumps(package(a.source,a.dylib,a.destination)))
