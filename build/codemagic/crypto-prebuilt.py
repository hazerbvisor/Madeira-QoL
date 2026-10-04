#!/usr/bin/env python3
"""Reuse the tracked crypto archives and stage public headers from pinned source."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile

from native_archives import verify_archive

ROOT = Path(__file__).resolve().parents[2]


def main():
    pins = json.loads((ROOT / 'build/gnutls-ios/prebuilt-pins.json').read_text())
    payloads = {}
    for relative, expected in pins['archives'].items():
        # clean-native intentionally removes these tracked files. Read their
        # pinned bytes from Git, rather than trusting another build's overwrite.
        data = subprocess.check_output(['git', '-C', str(ROOT), 'show', 'HEAD:' + relative])
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('tracked crypto checksum mismatch: ' + relative)
        print(f'Verified {relative}: {verify_archive(data)} ARM64 iOS objects')
        payloads[relative] = data
        payloads['toolchains/gnutls-ios/lib/' + Path(relative).name] = data
    source = ROOT / pins['headers']['archive']
    if hashlib.sha256(source.read_bytes()).hexdigest() != pins['headers']['sha256']:
        raise ValueError('GnuTLS source checksum mismatch')
    values = {'@VERSION@': '3.8.9', '@MAJOR_VERSION@': '3', '@MINOR_VERSION@': '8',
              '@PATCH_VERSION@': '9', '@NUMBER_VERSION@': '0x030809',
              '@DEFINE_IOVEC_T@': '#include <sys/uio.h>\ntypedef struct iovec giovec_t;'}
    prefix = 'gnutls-3.8.9/lib/includes/gnutls/'
    with tarfile.open(source) as archive:
        for member in archive.getmembers():
            if not member.isfile() or not member.name.startswith(prefix):
                continue
            name = member.name[len(prefix):]
            if '/' in name or name not in pins['headers']['files']:
                continue
            data = archive.extractfile(member).read()
            if name == 'gnutls.h.in':
                text = data.decode()
                if set(re.findall(r'@[A-Za-z0-9_]+@', text)) != set(values):
                    raise ValueError('unexpected GnuTLS header template substitutions')
                for key, value in values.items():
                    text = text.replace(key, value)
                name, data = 'gnutls.h', text.encode()
            payloads['toolchains/gnutls-ios/include/gnutls/' + name] = data
    if len([p for p in payloads if '/include/' in p]) != len(pins['headers']['files']):
        raise ValueError('incomplete GnuTLS public headers')
    # All bytes and architectures are checked before staging any files.
    for relative in payloads:
        path = ROOT / relative
        if path.is_symlink() or path.resolve() != path:
            raise ValueError('symlink in crypto destination: ' + relative)
    for relative, data in payloads.items():
        path = ROOT / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print('Using four tracked crypto archives; staged GnuTLS 3.8.9 public headers without compiling')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit('Crypto prebuilt input rejected: ' + str(error))
