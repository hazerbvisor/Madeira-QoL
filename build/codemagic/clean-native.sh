#!/bin/bash
# Remove only explicitly enumerated generated native products. This deliberately
# removes tracked GnuTLS archives locally so verification cannot reuse them.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R"
python3 - <<'PY'
import json, pathlib
for relative in json.loads(pathlib.Path('build/codemagic/native-libraries.json').read_text()):
    pathlib.Path(relative).unlink(missing_ok=True)
PY
rm -rf FEX/build-ios toolchains/llvm-ios-build toolchains/llvm-host-build \
    toolchains/gnutls-ios toolchains/ffmpeg-ios wine/build-macos \
    build/wineserver/obj build/dxmt-ios/obj build/dxmt-ios/shader-headers \
    build/ntdll-unix/obj build/win32u-unix/obj build/ffmpeg/obj \
    build/gnutls-ios/obj build/freetype-ios/build build/rppairing-ios/target
rm -f build/dxmt-ios/libdxmt_unix.a build/dxmt-ios/libdxmt_combined.a \
    app/Madeira/arm64ec-windows/dockhost.exe app/Madeira/arm64ec-windows/dock-notices.txt
