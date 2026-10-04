#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R"
[ "$(uname -s)" = Darwin ] || { echo 'Native iOS bootstrap requires macOS and Xcode' >&2; exit 1; }
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
export MADEIRA_ALLOW_NO_D3D12=0
bash build/codemagic/private-inputs.sh
bash build/codemagic/toolchains.sh
bash build/codemagic/wine-headers.sh
bash build/gnutls-ios/build.sh
bash build/ffmpeg/build.sh
case "${MADEIRA_USE_PREBUILT_FEX:-1}" in
    1) python3 build/codemagic/fex-prebuilt.py ;;
    0) bash build/fex-ios/build.sh ;;
    *) echo 'MADEIRA_USE_PREBUILT_FEX must be 0 or 1' >&2; exit 1 ;;
esac
# FreeType is actually merged into win32u, rather than linked separately.
SRC="$R/research/freetype"
REV=42608f77f20749dd6ddc9e0536788eaad70ea4b5
if [ ! -d "$SRC/.git" ]; then
    git init "$SRC"
    git -C "$SRC" remote add origin https://github.com/freetype/freetype.git
fi
git -C "$SRC" fetch --depth 1 origin "$REV"
git -C "$SRC" checkout --detach "$REV"
bash build/freetype-ios/build.sh
bash build/ntdll-unix/build.sh
bash build/wineserver/build.sh all
bash build/win32u-unix/build.sh
bash build/llvm-ios/build.sh
bash build/dxmt-ios/build.sh
bash build/rppairing-ios/build.sh
# Dock is an existing app resource that is ignored in a fresh clone.
bash build/madeira-dock/build.sh
bash build/stage-licenses.sh
python3 build/codemagic/verify-link-inputs.py
