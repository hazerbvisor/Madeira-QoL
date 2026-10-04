"""Validate ordinary ARM64 iOS static archives without depending on macOS tools."""
import struct


def verify_archive(data):
    if data[:8] != b'!<arch>\n':
        raise ValueError('not a static archive')
    offset, count = 8, 0
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b'`\n':
            raise ValueError('invalid archive member header')
        size = int(header[48:58])
        name = header[:16].decode().strip()
        member = data[offset + 60:offset + 60 + size]
        if len(member) != size:
            raise ValueError('truncated archive member')
        if name.startswith('#1/'):
            length = int(name[3:])
            name, member = member[:length].decode().rstrip('\0'), member[length:]
        if name not in ('/', '//', '/SYM64/') and not name.startswith('__.SYMDEF'):
            if len(member) < 32 or struct.unpack_from('<II', member) != (0xfeedfacf, 0x0100000c):
                raise ValueError('not an ARM64 Mach-O object: ' + name)
            if struct.unpack_from('<I', member, 12)[0] != 1:
                raise ValueError('not a relocatable object: ' + name)
            position, ios = 32, False
            for _ in range(struct.unpack_from('<I', member, 16)[0]):
                command, length = struct.unpack_from('<II', member, position)
                if length < 8 or position + length > len(member):
                    raise ValueError('invalid load command: ' + name)
                if command == 0x32:
                    ios = struct.unpack_from('<I', member, position + 8)[0] == 2
                elif command == 0x25:
                    ios = True
                position += length
            if not ios:
                raise ValueError('not an iOS device object: ' + name)
            count += 1
        offset += 60 + size + size % 2
    if offset != len(data) or not count:
        raise ValueError('empty or malformed archive')
    return count
