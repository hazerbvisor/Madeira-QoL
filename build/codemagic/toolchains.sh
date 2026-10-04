#!/bin/bash
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
NAME=llvm-mingw-20260421-ucrt-macos-universal
SHA=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
T="$R/toolchains"
mkdir -p "$T/downloads"
FILE="$T/downloads/$NAME.tar.xz"
if [ ! -f "$FILE" ]; then
    curl --fail --location --retry 3 "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$NAME.tar.xz" -o "$FILE.tmp"
    mv "$FILE.tmp" "$FILE"
fi
printf '%s  %s\n' "$SHA" "$FILE" | shasum -a 256 -c -
# Always extract verified bytes; cache contents must not bypass integrity checks.
tar -xf "$FILE" -C "$T"
[ -x "$T/$NAME/bin/aarch64-w64-mingw32-clang" ]
