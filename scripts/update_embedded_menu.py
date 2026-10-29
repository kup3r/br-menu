#!/usr/bin/env python3
"""Replace the existing embedded menu in a NEW unsigned IPA; copy other ZIP records.

No executable is run. Input IPA remains unchanged; --client24 also replaces the
validated client with the default-pass water gate.
"""
from pathlib import Path
import argparse, copy, hashlib, json, shutil, struct, zipfile

MENU = 'Payload/BrBase.app/Frameworks/BRMenuInject.dylib'
CLIENT = 'Payload/BrBase.app/Frameworks/blackrussia-client.framework/blackrussia-client'
def digest(path):
    with open(path, 'rb') as handle: return hashlib.file_digest(handle, 'sha256').hexdigest()

def package(source, menu, destination, client24=False, client25=False):
    if destination.exists() or destination.resolve() == source.resolve():
        raise ValueError('Choose a new output path')
    before = digest(source); library = menu.read_bytes()
    magic, cpu, subtype, kind = struct.unpack_from('<4I', library)
    if (magic, cpu, kind) != (0xfeedfacf, 0x100000c, 6): raise ValueError('Expected arm64 dylib')
    for name in ('BRMenuQueueHook15', 'BRMenuAspectHook17', 'BRMenuImpact21', 'BRMenuEntry'):
        if name.encode()+b'\0' not in library: raise ValueError('Missing menu entry/export: '+name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as original, open(source, 'rb') as raw:
        items = original.infolist()
        if sum(x.filename == MENU for x in items) != 1: raise ValueError('Expected one embedded menu')
        if len(set(x.filename for x in items)) != len(items): raise ValueError('Duplicate ZIP names')
        main = original.read('Payload/BrBase.app/BrBase')
        if b'@executable_path/Frameworks/BRMenuInject.dylib\0' not in main:
            raise ValueError('Missing pre-existing menu dependency')
        replacements={MENU:library}
        if client25:
            from patch_client25 import patch
            if b'BRMenuIncoming25\0' not in library: raise ValueError('Missing incoming-message export')
            replacements[CLIENT]=patch(original.read(CLIENT))
        elif client24:
            from patch_client24 import patch
            if b'BRMenuWater24\0' not in library: raise ValueError('Missing water gate export')
            replacements[CLIENT]=patch(original.read(CLIENT))
        # Keep every unchanged local ZIP record, including compression and descriptors.
        ordered = sorted(items, key=lambda x: x.header_offset)
        with zipfile.ZipFile(destination, 'w', allowZip64=True) as output:
            output.comment = original.comment
            for index, item in enumerate(ordered):
                record = copy.copy(item)
                if item.filename in replacements:
                    output.writestr(record, replacements[item.filename])
                    continue
                end = ordered[index+1].header_offset if index+1 < len(ordered) else original.start_dir
                raw.seek(item.header_offset)
                record.header_offset = output.start_dir
                output.fp.seek(output.start_dir)
                remaining = end-item.header_offset
                while remaining:
                    block = raw.read(min(1024*1024, remaining))
                    if not block: raise ValueError('Truncated input ZIP record')
                    output.fp.write(block); remaining -= len(block)
                output.start_dir = output.fp.tell()
                output.filelist.append(record); output.NameToInfo[record.filename] = record
                output._didModify = True
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination) as output:
        if output.testzip() is not None: raise ValueError('ZIP CRC check failed')
        if set(original.namelist()) != set(output.namelist()): raise ValueError('Entry inventory changed')
        changed = []
        for name in original.namelist():
            if hashlib.sha256(original.read(name)).digest() != hashlib.sha256(output.read(name)).digest(): changed.append(name)
        if set(changed) != set(replacements): raise ValueError('Unexpected changed members: '+repr(changed))
    if digest(source) != before: raise ValueError('Source unexpectedly changed')
    return dict(output=str(destination), size_bytes=destination.stat().st_size, sha256=digest(destination),
                source_sha256=before, changed_members=changed, menu_embedded=True,
                requires_full_resigning=True, game_runtime_tested=False)

if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('source',type=Path);parser.add_argument('menu',type=Path);parser.add_argument('destination',type=Path)
    parser.add_argument('--client24',action='store_true');parser.add_argument('--client25',action='store_true')
    args=parser.parse_args();print(json.dumps(package(args.source,args.menu,args.destination,args.client24,args.client25),ensure_ascii=False,indent=2))

