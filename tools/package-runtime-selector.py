#!/usr/bin/env python3
"""Assemble a dual-runtime unsigned IPA with the byte-identical original release.

Original resources/helper remain unchanged. Optional verified Microsoft runtime
files go in a QoL-only folder, never the original runtime's resource directory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import zipfile

ORIGINAL_SHA256 = "71e900cbc140778bd6fa67c1062821981ed98e6bfb674d853cfeefd6d242e1c0"
ROOT = "Payload/Madeira.app/"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def macho(data):
    header = struct.unpack_from("<8I", data)
    if header[0] != 0xFEEDFACF or header[1] != 0x100000C:
        raise ValueError("Expected a thin arm64 Mach-O")
    result = {"type": header[3], "dependencies": [], "defined_symbols": set()}
    offset = 32
    for _ in range(header[4]):
        cmd, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > len(data):
            raise ValueError("Malformed Mach-O commands")
        if cmd == 0x32:
            platform, minimum, sdk = struct.unpack_from("<3I", data, offset + 8)
            if platform != 2:
                raise ValueError("Expected iOS device build")
            result.update(minimum=minimum, sdk=sdk)
        if cmd in (0xC, 0x80000018, 0x8000001F):
            start = offset + struct.unpack_from("<I", data, offset + 8)[0]
            result["dependencies"].append(data[start:data.index(b"\0", start)].decode())
        if cmd == 2:
            symoff, count, strings, size = struct.unpack_from("<4I", data, offset + 8)
            for index in range(count):
                nameoff, kind, section, desc, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
                if kind & 0xE == 0xE and kind & 1 and not kind & 0xE0:
                    start = strings + nameoff
                    result["defined_symbols"].add(data[start:data.index(b"\0", start)].decode())
        offset += length
    if "minimum" not in result or "_main" not in result["defined_symbols"]:
        raise ValueError("Runtime/launcher lacks an iOS build version or defined main entry point")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original-ipa", required=True, type=Path)
    parser.add_argument("--binaries", required=True, type=Path)
    parser.add_argument("--vcruntime", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if sha(args.original_ipa.read_bytes()) != ORIGINAL_SHA256:
        parser.error("Original IPA is not the pinned, unmodified Madeira v0.1.3 release")
    launcher = (args.binaries / "MadeiraRuntimeLauncher").read_bytes()
    qol = (args.binaries / "MadeiraQoL.dylib").read_bytes()
    launcher_info, qol_info = macho(launcher), macho(qol)
    if launcher_info["type"] != 2 or qol_info["type"] != 6:
        parser.error("Launcher must be an executable; QoL runtime must be a dylib")
    if any("Madeira" in path for path in launcher_info["dependencies"]):
        parser.error("Launcher must not load either runtime through static dependencies")
    if any(name.startswith(("_wine_", "_wineserver_", "_fex_", "_madeira_spatial", "_$s7Madeira"))
           for name in launcher_info["defined_symbols"]):
        parser.error("Launcher contains runtime implementations")
    if any("Madeira.debug.dylib" in path for path in qol_info["dependencies"]):
        parser.error("QoL runtime must not link the original runtime")
    if args.vcruntime:
        subprocess.run(["python3", str(Path(__file__).with_name("verify-vcruntime.py")),
                        str(args.vcruntime)], check=True)
        if not any(path.is_file() and "license" in path.name.lower()
                   and path.suffix.lower() in (".txt", ".rtf") for path in args.vcruntime.iterdir()):
            parser.error("Supply the Microsoft runtime licence beside the DLLs")
    repository = Path(__file__).resolve().parents[1]
    revision = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
    dirty = bool(subprocess.check_output(["git", "-C", str(repository), "diff", "--name-only"], text=True).strip())
    preserved = {}
    with zipfile.ZipFile(args.original_ipa) as original:
        original_runtime = original.read(ROOT + "Madeira.debug.dylib")
        if macho(original_runtime)["type"] != 6:
            parser.error("Original app runtime must be a dylib")
        manifest = {
            "default": "original", "restart_required": True, "one_runtime_per_process": True,
            "original_release": "willfaust/Madeira v0.1.3", "original_ipa_sha256": ORIGINAL_SHA256,
            "original_runtime_sha256": sha(original_runtime), "qol_runtime_sha256": sha(qol),
            "launcher_sha256": sha(launcher), "qol_source_commit": revision, "source_dirty": dirty,
            "device_tested": False, "unsigned": True,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as packed:
            for info in original.infolist():
                if "/_CodeSignature/" in info.filename or info.filename.endswith("embedded.mobileprovision"):
                    continue
                data = original.read(info)
                if info.filename == ROOT + "Madeira":
                    data = launcher
                elif info.filename == ROOT + "Info.plist":
                    plist = plistlib.loads(data)
                    plist["MadeiraBuild"] = "Dual runtime: Original Madeira / Madeira-QoL"
                    plist["MadeiraRuntimeSelector"] = True
                    data = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY)
                elif not info.is_dir():
                    preserved[info.filename] = sha(data)
                info.compress_type = zipfile.ZIP_STORED
                packed.writestr(info, data)
            original_file_count = len(preserved)

            def add(name, data, mode=0o644):
                info = zipfile.ZipInfo(ROOT + name)
                info.external_attr = (stat.S_IFREG | mode) << 16
                packed.writestr(info, data)

            add("MadeiraQoL.dylib", qol, 0o755)
            add("MadeiraRuntimeManifest.json", json.dumps(manifest, indent=2).encode())
            add("MadeiraRuntimeSources.txt", (
                "Original: https://github.com/willfaust/Madeira/tree/4e9d45a74294cd820120791c4b3f2b79adf4fc70\n"
                "QoL: https://github.com/hazerbvisor/Madeira-QoL/tree/" + revision + "\n"
                "Launcher and packaging: tools/package-runtime-selector.py, tools/build-runtime-selector.py, app/RuntimeLauncher\n"
                "Licences and corresponding-source details: docs/LICENSING.md and repository LICENSES/\n"
            ).encode())
            if args.vcruntime:
                for path in sorted(args.vcruntime.iterdir()):
                    if path.is_file() and path.suffix.lower() in (".dll", ".txt", ".rtf"):
                        data = path.read_bytes()
                        name = "qol-x86_64-vcruntime/" + path.name
                        add(name, data)
                        preserved[ROOT + name] = sha(data)
    with zipfile.ZipFile(args.output) as packed:
        if packed.testzip() is not None or len(packed.namelist()) != len(set(packed.namelist())):
            raise ValueError("Invalid IPA or duplicate entries")
        for name, digest in preserved.items():
            if sha(packed.read(name)) != digest:
                raise ValueError("Original resource/helper/runtime changed: " + name)
        if packed.read(ROOT + "Madeira.debug.dylib") != original_runtime:
            raise ValueError("Original runtime changed")
    manifest.update(artifact=args.output.name, bytes=args.output.stat().st_size,
                    sha256=sha(args.output.read_bytes()), original_files_preserved=original_file_count,
                    qol_overlay_files_verified=len(preserved) - original_file_count)
    args.output.with_suffix(".build.json").write_text(json.dumps(manifest, indent=2))
    args.output.with_suffix(".ipa.sha256").write_text(manifest["sha256"] + "  " + args.output.name + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
