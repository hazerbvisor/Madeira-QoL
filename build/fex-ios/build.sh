#!/bin/bash
# Configure and build the FEXCore static libraries the app links
# (FEX/build-ios/FEXCore/Source/*.a and External/*). Options mirror the
# development build's CMakeCache.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$R/FEX/build-ios"
# Reconfigure on every run: a failed configure also creates CMakeCache.txt.
# The pinned fork's native tuning probes /proc/cpuinfo. A cross-built iOS
# library must use the target ABI, independent of the runner CPU.
cmake -S "$R/FEX" -B "$B" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DTUNE_CPU=none -DTUNE_ARCH=generic \
        -DCMAKE_PROJECT_INCLUDE="$R/build/fex-ios/native-compat.cmake" \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF \
        -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_xxhash=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON
cmake --build "$B" --target FEXCore FEXCore_Base JemallocLibs fmt xxhash cephes_128bit softfloat_3e --parallel "${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
ls "$B/FEXCore/Source/"*.a
