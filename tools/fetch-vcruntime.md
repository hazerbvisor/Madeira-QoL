# Obtaining the Microsoft Visual C++ runtime DLLs

Games built with MSVC need the Visual C++ runtime. Those DLLs are authored by
Microsoft and are **not** redistributable under this project's license, so they
are not committed here. Codemagic downloads and extracts a pinned official
redistributable automatically; private provisioning is also supported.

Twelve files are expected in `app/Madeira/x86_64-vcruntime/`:

```
concrt140.dll              msvcp140_codecvt_ids.dll   vcruntime140.dll
msvcp140.dll               vcamp140.dll               vcruntime140_1.dll
msvcp140_1.dll             vccorlib140.dll            vcruntime140_threads.dll
msvcp140_2.dll             vcomp140.dll
msvcp140_atomic_wait.dll
```

## How to get them

The tested automatic path on macOS is:

```sh
brew install sevenzip
python3 tools/fetch-vcruntime.py
```

The script downloads Microsoft's official Visual C++ 2015–2022 x64 runtime
14.44.35211 from the immutable URL in `tools/vcruntime-pins.json`. It verifies the
installer's SHA-256, extracts both WiX Burn cabinets with 7-Zip, reads the Burn
manifest to select the x64 runtime cabinet, and extracts the twelve DLLs above.
A direct `7zz x VC_redist.x64.exe` only exposes this installer's bootstrapper
cabinet; it does not extract the runtime DLLs by itself. The actual payload names
end in `.dll_amd64`; the script renames these file identifiers without altering
the DLL contents.

Every automatically extracted DLL is checked against a pinned SHA-256 and checked
for x64 PE architecture and an intact Authenticode certificate payload. These
structural checks do not perform certificate chain validation; the installer and
per-file hashes establish byte identity with the downloaded Microsoft release.

The installer is cached under `toolchains/downloads/`; the DLLs are staged under
`app/Madeira/x86_64-vcruntime/`. Both locations are ignored by Git. No Madeira IPA
is used. `--cache-dir`, `--destination` and `--sevenzip` allow isolated verification:

```sh
python3 tools/fetch-vcruntime.py --cache-dir /tmp/vc-cache --destination /tmp/vc-dlls
python3 tools/fetch-vcruntime.py --verify-only --destination /tmp/vc-dlls
```

For privately supplied runtime DLLs instead, see the environment variable overrides
in [docs/CODEMAGIC.md](../docs/CODEMAGIC.md). Retain Microsoft's redistribution
terms and supply the complete set without stripping or patching their bytes.

## Do not modify them

Microsoft's redistribution permission covers the eligible files *unmodified*.
In particular, do not strip Authenticode signatures. You can check that a file
still carries its signature payload:

```sh
python3 - app/Madeira/x86_64-vcruntime/*.dll <<'EOF'
import struct, sys
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    off, size = struct.unpack_from('<II', d, pe + 24 + 112 + 4*8)
    ok = size and off + size <= len(d)
    print(('signed  ' if ok else 'UNSIGNED'), path)
EOF
```

A file whose certificate offset equals its own length has had the signature
truncated off and is no longer an unmodified Microsoft binary.
