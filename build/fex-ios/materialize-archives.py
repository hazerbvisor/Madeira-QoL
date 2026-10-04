#!/usr/bin/env python3
"""Materialize compiled FEX LLVM IR archives as native ARM64 iOS archives."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--compiler', default='clang')
    parser.add_argument('--archiver', default='llvm-ar')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    inventory = json.loads((root / 'build/codemagic/native-libraries.json').read_text())
    paths = [p.removeprefix('FEX/build-ios/') for p in inventory if p.startswith('FEX/build-ios/')]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='madeira-fex-') as temporary:
        work = Path(temporary)
        jobs, archives = [], {}
        for relative in paths:
            original = args.build_dir / relative
            members = subprocess.check_output([args.archiver, 't', str(original)], text=True).splitlines()
            if not members or len(members) != len(set(members)):
                raise ValueError('empty archive or duplicate member names: ' + relative)
            directory = work / original.name
            directory.mkdir()
            destinations = []
            for member in members:
                if Path(member).name != member:
                    raise ValueError('invalid archive member name: ' + member)
                source, destination = directory / (member + '.ir'), directory / member
                source.write_bytes(subprocess.check_output([args.archiver, 'p', str(original), member]))
                jobs.append((source, destination))
                destinations.append(destination)
            archives[relative] = destinations

        def materialize(job):
            source, destination = job
            subprocess.run([args.compiler, '--target=arm64-apple-ios17.0', '-O3', '-fPIC',
                            '-c', '-x', 'ir', str(source), '-o', str(destination)], check=True)
            data = destination.read_bytes()
            if struct.unpack_from('<II', data) != (0xfeedfacf, 0x0100000c):
                raise ValueError('compiler did not emit ARM64 Mach-O: ' + str(destination))

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            list(pool.map(materialize, jobs))
        for relative, members in archives.items():
            destination = args.output_dir / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.unlink(missing_ok=True)
            subprocess.run([args.archiver, 'rcsD', str(destination), *map(str, members)], check=True)
            print(relative)
        for relative in ('include', 'generated'):
            shutil.copytree(args.build_dir / relative, args.output_dir / relative, dirs_exist_ok=True)
        print(f'Materialized {len(jobs)} compiled objects into {len(archives)} archives')


if __name__ == '__main__':
    main()
