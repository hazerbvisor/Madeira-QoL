#!/usr/bin/env python3
"""Check the required Microsoft x64 runtime payload in a directory or IPA.

An optional --reference directory verifies byte-for-byte packaging against the
original extracted files. Certificate-envelope checks do not verify signer trust.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import zipfile

REQUIRED = (
    "concrt140.dll", "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll", "msvcp140_codecvt_ids.dll", "vcamp140.dll",
    "vccorlib140.dll", "vcomp140.dll", "vcruntime140.dll",
    "vcruntime140_1.dll", "vcruntime140_threads.dll",
)
PREFIX = "Payload/Madeira.app/x86_64-vcruntime/"


def inspect(data, name):
    def read(fmt, offset):
        if offset < 0 or offset + struct.calcsize(fmt) > len(data):
            raise ValueError(f"{name}: truncated PE or certificate header")
        return struct.unpack_from(fmt, data, offset)

    pe, = read("<I", 60)
    if data[:2] != b"MZ" or data[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"{name}: invalid PE image")
    machine, = read("<H", pe + 4)
    optional_bytes, = read("<H", pe + 20)
    characteristics, = read("<H", pe + 22)
    magic, = read("<H", pe + 24)
    if machine != 0x8664 or magic != 0x20B or optional_bytes < 152 or not characteristics & 0x2000:
        raise ValueError(f"{name}: expected an x86_64 PE32+ DLL")
    certificate, size = read("<II", pe + 24 + 112 + 4 * 8)
    if not certificate or size < 8 or certificate % 8 or certificate + size > len(data):
        raise ValueError(f"{name}: missing or truncated Authenticode certificate")
    length, revision, kind = read("<IHH", certificate)
    if length < 8 or length > size or revision != 0x200 or kind != 2:
        raise ValueError(f"{name}: invalid Authenticode certificate envelope")


def verify(path, reference=None):
    archive = None
    try:
        if path.is_dir():
            read = lambda name: (path / name).read_bytes()
        else:
            archive = zipfile.ZipFile(path)
            names = archive.namelist()
            for name in REQUIRED:
                if names.count(PREFIX + name) != 1:
                    raise ValueError(f"{name}: expected exactly one runtime DLL in the IPA")
            read = lambda name: archive.read(PREFIX + name)
        for name in REQUIRED:
            data = read(name)
            inspect(data, name)
            if reference is not None and data != (reference / name).read_bytes():
                raise ValueError(f"{name}: differs from the original reference file")
            print(f"{name}: {hashlib.sha256(data).hexdigest()}")
    finally:
        if archive is not None:
            archive.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload", type=Path, help="Runtime directory or packaged IPA")
    parser.add_argument("--reference", type=Path, help="Unmodified runtime DLL directory")
    args = parser.parse_args()
    try:
        verify(args.payload, args.reference)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Runtime payload verification failed: {error}\n")
    suffix = "; bytes match the reference files" if args.reference else ""
    print("PASS: all 12 x64 DLLs have valid PE and certificate envelopes" + suffix)


if __name__ == "__main__":
    main()
