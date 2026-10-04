#!/bin/bash
# Pinned LLVM for DXMT; both tablegen and dependency resolution use this source.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
REV=8dfdcc7b7bf66834a761bd8de445840ef68e4d1a
SRC="$R/toolchains/llvm-project"
HOST="$R/toolchains/llvm-host-build"
IOS="$R/toolchains/llvm-ios-build"
JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
mkdir -p "$R/toolchains"
if [ ! -d "$SRC/.git" ]; then
    git init "$SRC"
    git -C "$SRC" remote add origin https://github.com/llvm/llvm-project.git
fi
if ! git -C "$SRC" cat-file -e "$REV^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch --depth 1 origin "$REV"
fi
git -C "$SRC" checkout --detach "$REV"
# Include the SDK/compiler identity in cache validity. Empty caches take the
# exact same configure/build path; no archive is imported from an IPA.
STAMP="$REV|$(xcodebuild -version)|$(xcrun --sdk iphoneos --show-sdk-version)|v2"
if [ "$(cat "$IOS/madeira-build-key" 2>/dev/null || true)" != "$STAMP" ]; then
    rm -rf "$HOST" "$IOS"
fi
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=
    -DLLVM_ENABLE_PROJECTS= -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_UTILS=OFF
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_RTTI=OFF -DLLVM_ENABLE_EH=OFF)
cmake -S "$SRC/llvm" -B "$HOST" "${COMMON[@]}"
cmake --build "$HOST" --target llvm-tblgen --parallel "$JOBS"
cmake -S "$SRC/llvm" -B "$IOS" "${COMMON[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_TARGET_ARCH=host -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" \
    -DCMAKE_PROJECT_INCLUDE="$R/build/llvm-ios/dependencies.cmake"
# The pinned source's CMake component graph resolves transitive dependencies
# before any archives exist; llvm-config --libnames would fail at that point.
read -r -a TARGETS < "$IOS/madeira-targets"
cmake --build "$IOS" --target "${TARGETS[@]}" --parallel "$JOBS"
printf '%s' "$STAMP" > "$IOS/madeira-build-key"
