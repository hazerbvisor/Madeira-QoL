#!/usr/bin/env python3
"""Verify and stage the seven published FEX ARM64 iOS libraries and headers."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PINS = ROOT / 'build/fex-ios/prebuilt-pins.json'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def verify_sources(pins):
    if git('-C', 'FEX', 'rev-parse', 'HEAD') != pins['fex_commit']:
        raise ValueError('FEX revision differs from the prebuilt input')
    lines = git('-C', 'FEX', 'submodule', 'status', '--recursive').splitlines()
    submodules = {'FEX/' + line.split()[1]: line.split()[0] for line in lines}
    if submodules != pins['submodules']:
        raise ValueError('FEX submodules differ from the prebuilt input; initialize pinned submodules')
    subprocess.run(['git', '-C', str(ROOT / 'FEX'), 'diff', '--quiet', 'HEAD', '--'], check=True)
    subprocess.run(['git', '-C', str(ROOT / 'FEX'), 'submodule', 'foreach', '--quiet', '--recursive',
                    'git diff --quiet HEAD --'], check=True)
    for relative, expected in pins['recipe_sha256'].items():
        if digest(ROOT / relative) != expected:
            raise ValueError('FEX build recipe differs from the prebuilt input: ' + relative)


def verify_archive(data):
    """Inspect every archive object, including BSD extended member names."""
    if data[:8] != b'!<arch>\n':
        raise ValueError('not a static archive')
    offset, count = 8, 0
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b'`\n':
            raise ValueError('invalid archive header')
        size = int(header[48:58])
        member = data[offset + 60:offset + 60 + size]
        if len(member) != size:
            raise ValueError('truncated archive')
        name = header[:16].decode().strip()
        if name.startswith('#1/'):
            length = int(name[3:])
            name, member = member[:length].decode().rstrip('\0'), member[length:]
        if name not in ('/', '//', '/SYM64/') and not name.startswith('__.SYMDEF'):
            if len(member) < 32 or struct.unpack_from('<II', member) != (0xfeedfacf, 0x0100000c):
                raise ValueError('archive contains an object that is not ARM64 Mach-O: ' + name)
            if struct.unpack_from('<I', member, 12)[0] != 1:
                raise ValueError('archive member is not a relocatable object: ' + name)
            command_offset, ios = 32, False
            for _ in range(struct.unpack_from('<I', member, 16)[0]):
                command, length = struct.unpack_from('<II', member, command_offset)
                if length < 8 or command_offset + length > len(member):
                    raise ValueError('invalid Mach-O load command: ' + name)
                if command == 0x32:  # LC_BUILD_VERSION, platform 2 = iOS device
                    platform, minimum = struct.unpack_from('<II', member, command_offset + 8)
                    ios = platform == 2 and minimum == (17 << 16)
                command_offset += length
            if not ios:
                raise ValueError('archive object does not target iOS 17.0: ' + name)
            count += 1
        offset += 60 + size + (size % 2)
    if offset != len(data) or not count:
        raise ValueError('empty or malformed archive')
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, default=ROOT, help='Repository root to stage into')
    parser.add_argument('--archive', type=Path, help='Verify an alternative copy of the pinned bundle')
    args = parser.parse_args()
    pins = json.loads(PINS.read_text())
    verify_sources(pins)
    archive = args.archive or ROOT / pins['archive']
    if digest(archive) != pins['sha256']:
        raise ValueError('FEX archive checksum mismatch: ' + str(archive))
    payloads = {}
    with tarfile.open(archive, 'r:gz') as bundle:
        members = bundle.getmembers()
        if len(members) != len(pins['files']) or {m.name for m in members} != set(pins['files']):
            raise ValueError('FEX bundle file inventory mismatch')
        for member in members:
            relative = Path(member.name)
            if not member.isfile() or relative.is_absolute() or '..' in relative.parts or not member.name.startswith('FEX/build-ios/'):
                raise ValueError('invalid FEX bundle path: ' + member.name)
            data = bundle.extractfile(member).read()
            if hashlib.sha256(data).hexdigest() != pins['files'][member.name]:
                raise ValueError('FEX bundle file checksum mismatch: ' + member.name)
            if relative.suffix == '.a':
                print(f'Verified {member.name}: {verify_archive(data)} ARM64 Mach-O objects')
            payloads[relative] = data
    destination = args.destination.resolve()
    # Validate the complete bundle before writing any output. Never follow a
    # pre-existing symlink out of the build directory.
    for relative in payloads:
        path = destination / relative
        if path.is_symlink() or path.resolve() != path:
            raise ValueError('symlink in FEX destination: ' + str(path))
    for relative, data in payloads.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print('Using seven precompiled FEX libraries and their generated headers (' + pins['fex_commit'][:12] + ')')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit('FEX prebuilt input rejected: ' + str(error) + '\nUse MADEIRA_USE_PREBUILT_FEX=0 to compile FEX from source.')
