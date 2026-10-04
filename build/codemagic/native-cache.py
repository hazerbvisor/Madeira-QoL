#!/usr/bin/env python3
"""Reuse completed native stages only when their sources, SDK and bytes match."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

from native_archives import verify_archive

ROOT = Path(__file__).resolve().parents[2]
SPEC_FILE = Path(__file__).with_name('native-components.json')
SPECS = json.loads(SPEC_FILE.read_text())


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def identity():
    return {'xcode': command('xcodebuild', '-version'),
            'sdk': command('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'),
            'clang': command('xcrun', '--sdk', 'iphoneos', 'clang', '--version'),
            'host_clang': command('clang', '--version')}


def key(name, platform, memo=None):
    memo = {} if memo is None else memo
    if name in memo:
        return memo[name]
    spec = SPECS[name]
    tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z', '--', *spec['inputs']]).decode().split('\0')
    files = {relative: file_sha(ROOT / relative) for relative in tracked
             if relative and relative not in spec.get('exclude', [])}
    submodules = {}
    for relative in spec.get('submodules', []):
        directory = ROOT / relative
        revision = command('git', '-C', str(directory), 'rev-parse', 'HEAD')
        diff = subprocess.check_output(['git', '-C', str(directory), 'diff', 'HEAD', '--'])
        submodules[relative] = {'revision': revision, 'diff_sha256': sha(diff)}
    tools = {tool: platform.get(tool) or command(tool, '--version') for tool in spec.get('tools', [])}
    inputs = {'schema': 1, 'component': name, 'platform': platform, 'files': files,
              'submodules': submodules, 'tools': tools,
              'external_revisions': spec.get('external_revisions', {}),
              'variables': {v: os.environ.get(v, '1') for v in spec.get('variables', [])},
              'dependencies': {d: key(d, platform, memo) for d in spec.get('dependencies', [])},
              'helper_sha256': file_sha(Path(__file__)),
              'archive_checker_sha256': file_sha(Path(__file__).with_name('native_archives.py')),
              'spec_sha256': file_sha(SPEC_FILE)}
    memo[name] = sha(json.dumps(inputs, sort_keys=True).encode())
    return memo[name]


def allowed(relative, spec):
    path = Path(relative)
    return (not path.is_absolute() and '..' not in path.parts and
            any(relative == output or relative.startswith(output + '/') for output in spec['outputs']))


def verify_payloads(payloads, spec):
    for output in spec['outputs']:
        if not any(p == output or p.startswith(output + '/') for p in payloads):
            raise ValueError('required output is absent: ' + output)
    for relative, data in payloads.items():
        if not allowed(relative, spec) or not data:
            raise ValueError('invalid or empty cached output: ' + relative)
        if relative.endswith('.a'):
            verify_archive(data)
        if relative.endswith('dockhost.exe'):
            if data[:2] != b'MZ':
                raise ValueError('Dock output is not a PE executable')
            import struct
            pe = struct.unpack_from('<I', data, 0x3c)[0]
            if data[pe:pe + 4] != b'PE\0\0' or struct.unpack_from('<H', data, pe + 4)[0] != 0x8664:
                raise ValueError('Dock output is not x86-64 PE')


def load_bundle(archive, name, fingerprint):
    with tarfile.open(archive, 'r:gz') as bundle:
        members = bundle.getmembers()
        manifest_member = bundle.getmember('manifest.json')
        if not manifest_member.isfile():
            raise ValueError('invalid cache manifest')
        manifest = json.loads(bundle.extractfile(manifest_member).read())
        if manifest.get('component') != name or manifest.get('key') != fingerprint:
            raise ValueError('cached source/SDK identity mismatch')
        expected = manifest['files']
        if len(members) != len(expected) + 1 or {m.name for m in members} != set(expected) | {'manifest.json'}:
            raise ValueError('cache inventory mismatch')
        payloads = {}
        for member in members:
            if member.name == 'manifest.json':
                continue
            if not member.isfile() or not allowed(member.name, SPECS[name]):
                raise ValueError('invalid cache path: ' + member.name)
            data = bundle.extractfile(member).read()
            if sha(data) != expected[member.name]:
                raise ValueError('cache checksum mismatch: ' + member.name)
            payloads[member.name] = data
    verify_payloads(payloads, SPECS[name])
    return payloads


def restore(archive, name, fingerprint, destination):
    if not archive.is_file():
        print('Native cache miss: ' + name)
        return False
    payloads = load_bundle(archive, name, fingerprint)
    destination = destination.resolve()
    for relative in payloads:
        path = destination / relative
        if path.is_symlink() or path.resolve() != path:
            raise ValueError('symlink in cache destination: ' + relative)
    for relative, data in payloads.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print('Reused native component: ' + name + ' (verified source, SDK and file checksums)')
    return True


def save(archive, name, fingerprint):
    paths = {}
    for output in SPECS[name]['outputs']:
        path = ROOT / output
        if path.is_file():
            paths[output] = path
        elif path.is_dir():
            for member in path.rglob('*'):
                if member.is_file():
                    paths[str(member.relative_to(ROOT))] = member
        else:
            raise ValueError('missing completed component output: ' + output)
    payloads = {relative: path.read_bytes() for relative, path in paths.items()}
    verify_payloads(payloads, SPECS[name])
    manifest = {'component': name, 'key': fingerprint,
                'files': {relative: sha(data) for relative, data in payloads.items()}}
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=archive.parent) as temporary:
        temporary = Path(temporary)
        manifest_path = temporary / 'manifest.json'
        manifest_path.write_text(json.dumps(manifest, sort_keys=True))
        packed = temporary / 'component.tar.gz'
        with tarfile.open(packed, 'w:gz', compresslevel=1, dereference=True) as bundle:
            bundle.add(manifest_path, arcname='manifest.json', recursive=False)
            for relative, path in sorted(paths.items()):
                bundle.add(path, arcname=relative, recursive=False)
        os.replace(packed, archive)
    print('Saved completed native component: ' + name)


def prepare(name):
    # Remove only this component's declared generated state. A source or SDK
    # change must not leave a builder's older .done/configure markers in use.
    for relative in SPECS[name]['clean']:
        path = ROOT / relative
        if path.parent.resolve() != path.parent:
            raise ValueError('symlink in generated-state parent: ' + relative)
        if path.is_symlink():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('restore', 'save', 'prepare', 'import'))
    parser.add_argument('component', choices=tuple(SPECS), nargs='?')
    parser.add_argument('--cache-dir', type=Path, default=ROOT / 'toolchains/native-cache')
    parser.add_argument('--destination', type=Path, default=ROOT)
    parser.add_argument('--identity-file', type=Path, help='Explicit tool identity for local cache verification')
    parser.add_argument('--bundle', type=Path, help='Completed component artifact to import')
    args = parser.parse_args()
    if args.action != 'import' and args.component is None:
        parser.error('component is required')
    if args.action == 'prepare':
        prepare(args.component)
        return 0
    platform = json.loads(args.identity_file.read_text()) if args.identity_file else identity()
    if args.action == 'import':
        if not args.bundle:
            parser.error('--bundle is required for import')
        with tarfile.open(args.bundle) as bundle:
            manifest = bundle.getmember('manifest.json')
            if not manifest.isfile():
                raise ValueError('invalid cache manifest')
            name = json.loads(bundle.extractfile(manifest).read())['component']
        if name not in SPECS:
            raise ValueError('unknown native component: ' + str(name))
        fingerprint = key(name, platform)
        load_bundle(args.bundle, name, fingerprint)
        destination = args.cache_dir / name / (fingerprint + '.tar.gz')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
            temporary = Path(temporary) / 'component.tar.gz'
            shutil.copyfile(args.bundle, temporary)
            os.replace(temporary, destination)
        print('Imported verified native component artifact: ' + name)
        return 0
    fingerprint = key(args.component, platform)
    archive = args.cache_dir / args.component / (fingerprint + '.tar.gz')
    if args.action == 'restore':
        try:
            return 0 if restore(archive, args.component, fingerprint, args.destination) else 1
        except (OSError, ValueError, KeyError, tarfile.TarError) as error:
            print('Native cache rejected for ' + args.component + ': ' + str(error) + '; rebuilding', file=sys.stderr)
            return 1
    save(archive, args.component, fingerprint)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit('Native cache failed: ' + str(error))
