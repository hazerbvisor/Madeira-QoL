#!/usr/bin/env python3
"""Audit every Xcode archive reference, reject unknown/missing/invalid inputs."""
import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / 'app/Madeira.xcodeproj/project.pbxproj'
MANIFEST = pathlib.Path(__file__).with_name('native-libraries.json')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', action='store_true', help='Print classifications without requiring outputs')
    args = parser.parse_args()
    inventory = json.loads(MANIFEST.read_text())
    references = re.findall(r'isa = PBXFileReference;[^\n]*lastKnownFileType = archive.ar;[^\n]*path = ("[^"]+"|[^;]+);', PROJECT.read_text())
    paths = {(('FEX/' + p.split('FEX/', 1)[1]) if 'FEX/' in p else 'app/Madeira/' + p) for p in (r.strip('"') for r in references)}
    failed = False
    for relative in sorted(paths):
        entry = inventory.get(relative)
        if entry is None:
            print(f'MISSING CLASSIFICATION: {relative}', file=sys.stderr)
            failed = True
            continue
        path = ROOT / relative
        print(f"{entry['classification']}: {relative} — {entry['builder']}")
        if args.audit:
            continue
        if not path.is_file() or path.stat().st_size == 0:
            print(f'UNAVAILABLE: {relative}; build with {entry["builder"]}', file=sys.stderr)
            failed = True
            continue
        try:
            result = subprocess.run(['ar', 't', str(path)], check=True, capture_output=True, text=True)
            if not result.stdout.strip():
                raise ValueError('empty archive')
            if sys.platform == 'darwin':
                subprocess.run(['xcrun', 'lipo', '-verify_arch', 'arm64', str(path)], check=True, capture_output=True)
        except (subprocess.CalledProcessError, ValueError) as exc:
            print(f'INVALID ARCHIVE: {relative}: {exc}', file=sys.stderr)
            failed = True
    for unused in sorted(set(inventory) - paths):
        print(f'STALE CLASSIFICATION: {unused}', file=sys.stderr)
        failed = True
    if not paths:
        print('No Xcode archives found; cannot verify link inputs', file=sys.stderr)
        failed = True
    return int(failed)

if __name__ == '__main__':
    sys.exit(main())
