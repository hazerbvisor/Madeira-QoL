#!/bin/bash
# Fetch/provision external inputs; never commit them or recover from an IPA.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
# Full D3D12 is the only CI mode. The pinned, already tracked converter is
# usable; optionally stage a privately provided copy at its existing location.
if [ -n "${MADEIRA_MSC_IOS_FILE:-}" ]; then
    cmp -s "$MADEIRA_MSC_IOS_FILE" "$R/app/Madeira/d3d12/libmetalirconverter.dylib" || \
        cp "$MADEIRA_MSC_IOS_FILE" "$R/app/Madeira/d3d12/libmetalirconverter.dylib"
fi
source "$R/build/madeira-d3d12/deps.sh"
# Preserve explicit runner inputs; otherwise bootstrap from Microsoft's pinned
# redistributable instead of requiring a previous build or a private ZIP.
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
else
    python3 "$R/tools/fetch-vcruntime.py" --destination "$DEST"
fi
python3 "$R/tools/fetch-vcruntime.py" --verify-only --destination "$DEST"
