#!/usr/bin/env python3
"""Fetch pinned Microsoft VC++ x64 runtime DLLs, without executing the installer."""
import argparse
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
PINS = json.loads(pathlib.Path(__file__).with_name('vcruntime-pins.json').read_text())


def checked_hash(path, expected, algorithm='sha256'):
    actual = hashlib.new(algorithm, path.read_bytes()).hexdigest()
    if actual != expected.lower():
        raise ValueError(f'{path.name}: {algorithm} mismatch (expected {expected}, found {actual})')


def check_dll(path):
    """Reject wrong architectures and stripped/truncated certificate payloads.

    This checks PE structure, not certificate trust. The pinned installer and
    per-DLL SHA-256 checks establish byte identity for automatic downloads.
    """
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError(f'{path.name}: invalid DOS header')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if pe + 24 + 152 > len(data) or data[pe:pe + 4] != b'PE\0\0':
        raise ValueError(f'{path.name}: invalid PE header')
    if struct.unpack_from('<H', data, pe + 4)[0] != 0x8664:
        raise ValueError(f'{path.name}: expected x86-64 DLL')
    optional = pe + 24
    if struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise ValueError(f'{path.name}: expected PE32+ optional header')
    offset, size = struct.unpack_from('<II', data, optional + 112 + 4 * 8)
    if size < 8 or offset < optional + 152 or offset + size > len(data):
        raise ValueError(f'{path.name}: missing or truncated Authenticode payload')
    length, revision, kind = struct.unpack_from('<IHH', data, offset)
    if not (8 <= length <= size and revision == 0x200 and kind == 2):
        raise ValueError(f'{path.name}: invalid Authenticode payload')


def extract(sevenzip, archive, destination):
    subprocess.run([sevenzip, 'x', '-y', '-bd', str(archive), '-o' + str(destination)],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def split_cabinets(installer, destination):
    # WiX Burn has a UX cabinet and an attached payload cabinet after the PE.
    # Running 7z on the EXE alone exposes only UX. Parse complete cabinet headers
    # in these hash-verified bytes instead of assuming a .rsrc/CABINET layout.
    data = installer.read_bytes()
    cabinets = []
    position = 0
    while True:
        position = data.find(b'MSCF', position)
        if position < 0:
            break
        if position + 36 <= len(data):
            size = struct.unpack_from('<I', data, position + 8)[0]
            if data[position + 24:position + 26] == b'\x03\x01' and 36 <= size <= len(data) - position:
                cabinet = destination / f'container-{len(cabinets)}.cab'
                cabinet.write_bytes(data[position:position + size])
                cabinets.append(cabinet)
                position += size
                continue
        position += 4
    if len(cabinets) != 2:
        raise ValueError(f'Expected two WiX Burn cabinets in the pinned installer, found {len(cabinets)}')
    return cabinets


def stage(installer, destination, sevenzip):
    checked_hash(installer, PINS['sha256'])
    with tempfile.TemporaryDirectory(prefix='madeira-vcruntime-') as tmp:
        tmp = pathlib.Path(tmp)
        ux_cab, payload_cab = split_cabinets(installer, tmp)
        ux, payload, dlls = (tmp / name for name in ('ux', 'payload', 'dlls'))
        extract(sevenzip, ux_cab, ux)
        manifest = ET.fromstring((ux / '0').read_bytes())
        matches = [e for e in manifest if e.attrib.get('FilePath') ==
                   r'packages\vcRuntimeMinimum_amd64\cab1.cab']
        if len(matches) != 1:
            raise ValueError('Cannot identify the x64 minimum-runtime cabinet in the Burn manifest')
        entry = matches[0].attrib
        extract(sevenzip, payload_cab, payload)
        cabinet = payload / entry['SourcePath']
        checked_hash(cabinet, entry['Hash'], 'sha1')
        extract(sevenzip, cabinet, dlls)
        # Validate the entire set before staging any file. Renaming an MSI file
        # identifier preserves the exact DLL bytes, including its signature.
        for name, sha in PINS['dll_sha256'].items():
            source = dlls / (name + '_amd64')
            checked_hash(source, sha)
            check_dll(source)
        destination.mkdir(parents=True, exist_ok=True)
        for name in PINS['dll_sha256']:
            shutil.copyfile(dlls / (name + '_amd64'), destination / name)
        print(f'Staged {len(PINS["dll_sha256"])} unmodified x64 runtime DLLs ({PINS["version"]})')


def verify_directory(directory):
    failures = []
    for name in PINS['dll_sha256']:
        try:
            check_dll(directory / name)
        except (OSError, ValueError, struct.error) as exc:
            failures.append(f'Unavailable runtime dependency: {directory / name}: {exc}')
    if failures:
        raise ValueError('\n'.join(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=pathlib.Path, default=ROOT / 'app/Madeira/x86_64-vcruntime')
    parser.add_argument('--cache-dir', type=pathlib.Path, default=ROOT / 'toolchains/downloads')
    parser.add_argument('--sevenzip', default=shutil.which('7zz') or shutil.which('7z'))
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if args.verify_only:
        verify_directory(args.destination)
        return
    if not args.sevenzip:
        raise ValueError('Missing 7-Zip: install with brew install sevenzip')
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    installer = args.cache_dir / f'vc_redist.x64-{PINS["version"]}.exe'
    if not installer.is_file():
        partial = installer.with_suffix('.exe.part')
        try:
            subprocess.run(['curl', '--fail', '--location', '--retry', '3', PINS['url'], '-o', str(partial)], check=True)
            checked_hash(partial, PINS['sha256'])
            partial.replace(installer)
        finally:
            partial.unlink(missing_ok=True)
    stage(installer, args.destination, args.sevenzip)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, struct.error, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f'vcruntime: {exc}', file=sys.stderr)
        sys.exit(1)
