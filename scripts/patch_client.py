#!/usr/bin/env python3
"""Patch a copy of the exact supplied client/IPA. Re-sign the IPA afterwards."""
import argparse,hashlib,json,struct,zipfile
from pathlib import Path
ORIGINAL_SHA='85c7e83cb5c471a31a01f4acd3ba7bb194a14823cc23c4ba229eba42401076b6'
CLIENT='Payload/BrBase.app/Frameworks/blackrussia-client.framework/blackrussia-client'
ENTRY=0xb06a00;BRIDGE=0x2000;TRAMPOLINE=0x2200;MANIFEST=0x2300
BRIDGE_HEX='ff4303d1e00700a9e20f01a9e41702a9e61f03a9fd7b04a9e08702ade28f03ade49704ade69f05ad20008092a1060010aa4d4994f00300aae08742ade28f43ade49744ade69f45adfd7b44a9e61f43a9e41742a9e20f41a9e00740a9ff430391700000b4e40c001000021fd665000014'
ASPECT_ENTRY=0x9f5fbc;ASPECT_BRIDGE=0x2500;ASPECT_SYMBOL=0x2d00;ASPECT_MANIFEST=0x2f00
ASPECT_HEX='ff430cd1e00700a9e20f01a9e41702a9e61f03a9e82704a9ea2f05a9ec3706a9ee3f07a9f04708a9f24f09a9f4570aa9f65f0ba9f8670ca9fa6f0da9fc770ea9fe7b00f909423bd5e97f00f9e00708ade20f09ade4170aade61f0bade8270cadea2f0dadec370eadee3f0fadf04710adf24f11adf45712adf65f13adf86714adfa6f15adfc7716adfe7f17ad20008092813b0010514c4994c00000b4f00300aae00341bd00023fd6e00303bd03000014e00341bde00303bde00748ade20f49ade4174aade61f4bade8274cadea2f4dadec374eadee3f4fadf04750adf24f51adf45752adf65f53adf86754adfa6f55adfc7756adfe7f57ade97f40f909421bd5e00740a9e20f41a9e41742a9e61f43a9e82744a9ea2f45a9ec3746a9ee3f47a9f04748a9f24f49a9f4574aa9f65f4ba9f8674ca9fa6f4da9fc774ea9fe7b40f9e00343bdff430c91006103bdc0035fd6'
MAGIC=b'BR15HOOK'
def branch(pc,target):
    d=target-pc
    if d%4 or not -(1<<27)<=d<(1<<27):raise ValueError('ARM64 branch out of range')
    return struct.pack('<I',0x14000000|((d//4)&0x3ffffff))
def patch(data):
    if hashlib.sha256(data).hexdigest()!=ORIGINAL_SHA:raise ValueError('Client SHA256 does not match the verified build; no output written')
    if any(data[0x2000:0x3000]):raise ValueError('Expected unused header padding is occupied')
    if data[ENTRY:ENTRY+16].hex()!='f85fbca9 f65701a9 f44f02a9 fd7b03a9'.replace(' ',''):
        raise ValueError('Unexpected original queue prologue')
    out=bytearray(data);bridge=bytes.fromhex(BRIDGE_HEX)
    out[BRIDGE:BRIDGE+len(bridge)]=bridge
    symbol=b'BRMenuQueueHook15\0';out[0x2100:0x2100+len(symbol)]=symbol
    trampoline=data[ENTRY:ENTRY+16]+branch(TRAMPOLINE+16,ENTRY+16)
    out[TRAMPOLINE:TRAMPOLINE+len(trampoline)]=trampoline
    manifest=MAGIC+struct.pack('<4I',1,ENTRY,BRIDGE,TRAMPOLINE)+bytes.fromhex(ORIGINAL_SHA)
    out[MANIFEST:MANIFEST+len(manifest)]=manifest
    out[ENTRY:ENTRY+4]=branch(ENTRY,BRIDGE)
    if data[ASPECT_ENTRY:ASPECT_ENTRY+8]!=bytes.fromhex('006103bdc0035fd6'):
        raise ValueError('Unexpected aspect writer; refusing to patch')
    aspect=bytes.fromhex(ASPECT_HEX);out[ASPECT_BRIDGE:ASPECT_BRIDGE+len(aspect)]=aspect
    symbol=b'BRMenuAspectHook17\0';out[ASPECT_SYMBOL:ASPECT_SYMBOL+len(symbol)]=symbol
    manifest=b'BR17VIEW'+struct.pack('<4I',1,ASPECT_ENTRY,ASPECT_BRIDGE,ASPECT_SYMBOL)
    out[ASPECT_MANIFEST:ASPECT_MANIFEST+len(manifest)]=manifest
    out[ASPECT_ENTRY:ASPECT_ENTRY+4]=branch(ASPECT_ENTRY,ASPECT_BRIDGE)
    return bytes(out)
def main():
    ap=argparse.ArgumentParser();ap.add_argument('source',type=Path);ap.add_argument('destination',type=Path);ap.add_argument('--client',action='store_true');args=ap.parse_args()
    if args.source.resolve()==args.destination.resolve() or args.destination.exists():raise SystemExit('Choose a new output path; source and existing files are never overwritten')
    if args.client:args.destination.write_bytes(patch(args.source.read_bytes()))
    else:
        with zipfile.ZipFile(args.source) as zin:
            patched=patch(zin.read(CLIENT))
            with zipfile.ZipFile(args.destination,'w',compresslevel=1,allowZip64=True) as zout:
                for item in zin.infolist():
                    data=patched if item.filename==CLIENT else zin.read(item)
                    zout.writestr(item,data,compresslevel=1)
    print(json.dumps({'output':str(args.destination),'requires_resigning':True,'requires_menu_dylib':'v17','silent_enabled_by_default':False,'client_sha256':hashlib.sha256(patched if not args.client else args.destination.read_bytes()).hexdigest()}))
if __name__=='__main__':main()
