#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$R"
[ "$(uname -s)" = Darwin ] || { echo 'Native iOS bootstrap requires macOS and Xcode' >&2; exit 1; }
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
export MADEIRA_ALLOW_NO_D3D12=0
export MADEIRA_USE_PREBUILT_CRYPTO="${MADEIRA_USE_PREBUILT_CRYPTO:-1}"
REUSE="${MADEIRA_REUSE_NATIVE:-1}"
for value in "$REUSE" "$MADEIRA_USE_PREBUILT_CRYPTO" "${MADEIRA_USE_PREBUILT_FEX:-1}"; do
    case "$value" in 0|1) ;; *) echo 'Native reuse/prebuilt flags must be 0 or 1' >&2; exit 1 ;; esac
done
[ "${MADEIRA_CLEAN_NATIVE:-0}" != 1 ] || REUSE=0

# Save each completed stage immediately. A later compile failure must not force
# successful components to be built again on the next Codemagic runner.
run_stage() {
    local name=$1
    shift
    if [ "$REUSE" = 1 ] && python3 build/codemagic/native-cache.py restore "$name"; then
        return
    fi
    python3 build/codemagic/native-cache.py prepare "$name"
    "$@"
    python3 build/codemagic/native-cache.py save "$name"
}

TOOLS_READY=0
ensure_toolchains() {
    if [ "$TOOLS_READY" = 0 ]; then
        bash build/codemagic/toolchains.sh
        TOOLS_READY=1
    fi
}
build_wine_headers() {
    ensure_toolchains
    bash build/codemagic/wine-headers.sh
}
build_crypto() {
    if [ "$MADEIRA_USE_PREBUILT_CRYPTO" = 1 ]; then
        python3 build/codemagic/crypto-prebuilt.py
    else
        bash build/gnutls-ios/build.sh
    fi
}
build_freetype() {
    local src="$R/research/freetype"
    local revision=42608f77f20749dd6ddc9e0536788eaad70ea4b5
    if [ ! -d "$src/.git" ]; then
        git init "$src"
        git -C "$src" remote add origin https://github.com/freetype/freetype.git
    fi
    if ! git -C "$src" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$src" fetch --depth 1 origin "$revision"
    fi
    git -C "$src" checkout --detach "$revision"
    bash build/freetype-ios/build.sh
}
build_dxmt() {
    bash build/llvm-ios/build.sh
    bash build/dxmt-ios/build.sh
}
build_dock() {
    ensure_toolchains
    bash build/madeira-dock/build.sh
}

bash build/codemagic/private-inputs.sh
# Optional artifacts from a previous failed Codemagic run. Codemagic's own
# dependency cache is exported only after a successful build.
if [ -n "${MADEIRA_NATIVE_BUNDLE_URLS:-}" ]; then
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        bundle=$(mktemp)
        if ! curl --fail --silent --show-error --location --retry 3 --proto '=https' "$url" -o "$bundle"; then
            python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)' "$bundle"
            exit 1
        fi
        python3 build/codemagic/native-cache.py import --bundle "$bundle"
        python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)' "$bundle"
    done <<< "$MADEIRA_NATIVE_BUNDLE_URLS"
fi
run_stage wine-headers build_wine_headers
run_stage crypto build_crypto
run_stage ffmpeg bash build/ffmpeg/build.sh
case "${MADEIRA_USE_PREBUILT_FEX:-1}" in
    1) python3 build/codemagic/fex-prebuilt.py ;;
    0) bash build/fex-ios/build.sh ;;
    *) echo 'MADEIRA_USE_PREBUILT_FEX must be 0 or 1' >&2; exit 1 ;;
esac
run_stage freetype build_freetype
run_stage ntdll bash build/ntdll-unix/build.sh
run_stage wineserver bash build/wineserver/build.sh all
run_stage win32u bash build/win32u-unix/build.sh
run_stage dxmt build_dxmt
run_stage rppairing bash build/rppairing-ios/build.sh
# Dock is an existing app resource that is ignored in a fresh clone.
run_stage dock build_dock
bash build/stage-licenses.sh
python3 build/codemagic/verify-link-inputs.py
