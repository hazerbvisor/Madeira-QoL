#!/bin/bash
# Host configuration supplies Wine's generated headers to the hand-built iOS
# unix archives. No host Wine archive is linked into the app.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
B="$R/wine/build-macos"
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
mkdir -p "$B"
cd "$B"
../configure --without-x --disable-tests --enable-winegstreamer
# These headers are tracked in the pinned fork; configure generates config.h.
for header in include/config.h ../include/ntstatus.h ../include/wine/server_protocol.h; do
    [ -s "$header" ] || { echo "Missing Wine header: $B/$header" >&2; exit 1; }
done
