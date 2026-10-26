import struct
import sys
from pathlib import Path
blob = Path(sys.argv[1]).read_bytes()
magic, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from('<8I', blob)
assert magic == 0xFEEDFACF and cpu == 0x100000C and kind == 6, 'Expected arm64 MH_DYLIB'
sections = []
offset = 32
for _ in range(count):
    command, size = struct.unpack_from('<II', blob, offset)
    assert size >= 8 and offset + size <= 32 + command_bytes
    if command == 0x19:
        for index in range(struct.unpack_from('<I', blob, offset + 64)[0]):
            start = offset + 72 + index * 80
            name = blob[start:start + 16].split(b'\0')[0].decode()
            section_size = struct.unpack_from('<Q', blob, start + 40)[0]
            if section_size:
                sections.append(name)
    offset += size
assert any(name in sections for name in ('__mod_init_func', '__init_offsets')), 'Missing load initializer'
assert b'BRMenuEntry\0' in blob, 'Missing Objective-C entry name'
print('Verified: arm64 MH_DYLIB, nonempty initializer section and Objective-C entry name. Runtime not tested.')
