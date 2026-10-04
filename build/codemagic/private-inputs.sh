#!/bin/bash
# Inputs are supplied by the runner, never committed or recovered from an IPA.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
# Full D3D12 is the only CI mode. The pinned, already tracked converter is
# usable; optionally stage a privately provided copy at its existing location.
if [ -n "${MADEIRA_MSC_IOS_FILE:-}" ]; then
    cmp -s "$MADEIRA_MSC_IOS_FILE" "$R/app/Madeira/d3d12/libmetalirconverter.dylib" || \
        cp "$MADEIRA_MSC_IOS_FILE" "$R/app/Madeira/d3d12/libmetalirconverter.dylib"
fi
source "$R/build/madeira-d3d12/deps.sh"
# Existing Microsoft DLL resources must be present to preserve guest behavior.
# Supply a directory on the runner or a private ZIP with DLLs at its root.
DEST="$R/app/Madeira/x86_64-vcruntime"
mkdir -p "$DEST"
if [ -n "${MADEIRA_VCRUNTIME_DIR:-}" ]; then
    cp "$MADEIRA_VCRUNTIME_DIR"/*.dll "$DEST/"
elif [ -n "${MADEIRA_VCRUNTIME_URL:-}" ]; then
    : "${MADEIRA_VCRUNTIME_SHA256:?Set the checksum of your private runtime ZIP}"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    curl --fail --location --retry 3 "$MADEIRA_VCRUNTIME_URL" -o "$TMP/runtime.zip"
    printf '%s  %s\n' "$MADEIRA_VCRUNTIME_SHA256" "$TMP/runtime.zip" | shasum -a 256 -c -
    unzip -q "$TMP/runtime.zip" -d "$TMP/runtime"
    cp "$TMP/runtime"/*.dll "$DEST/"
fi
for dll in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait \
    msvcp140_codecvt_ids vcamp140 vccorlib140 vcomp140 vcruntime140 \
    vcruntime140_1 vcruntime140_threads; do
    [ -s "$DEST/$dll.dll" ] || { echo "Missing external input: $DEST/$dll.dll (see docs/CODEMAGIC.md)" >&2; exit 1; }
done
