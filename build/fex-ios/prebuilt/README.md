# FEX ARM64 iOS build input

`fex-ios-arm64-26859e18-v1.tar.gz` contains the seven libraries already compiled
for this branch, their five generated headers, provenance and license notices.
It is committed here so a fresh Codemagic checkout can use it without a separate
artifact upload or cache. `../prebuilt-pins.json` records its checksum and inputs.

The source is the public FEX submodule at
`26859e184ad90f0e811d7f8bbd943a4b1573a2c3`, including its recursively pinned
dependencies. The corresponding parent recipe and native compatibility headers
are in `build/fex-ios/`. Initialize the complete corresponding source with:

```sh
git clone --branch fix/codemagic-clean-build --recurse-submodules \
  https://github.com/hazerbvisor/Madeira-QoL.git
```

The original build used Clang 21.0.0 from `swift:6.3.3-jammy`, iPhoneOS 26.5 headers
(SDK snapshot `ad607cb07fe4ad1c9b91cf970bd228c2a9253207`), target
`arm64-apple-ios17.0`, and the Release/options in `../build.sh`. The 154 compiled
LLVM objects were materialized with the same compiler backend using
`clang --target=arm64-apple-ios17.0 -O3 -fPIC -c -x ir`, then archived with
`llvm-ar rcsD`. The equivalent materialization tool is `../materialize-archives.py`:

```sh
python3 build/fex-ios/materialize-archives.py \
  --build-dir /path/to/compiled/fex-ios --output-dir /path/to/native/fex-ios
```

This does not recompile the C/C++ source. It converts already compiled IR to
standard ARM64 iOS Mach-O objects, avoiding LLVM bitcode version requirements at
the Xcode link. On macOS, `MADEIRA_USE_PREBUILT_FEX=0` runs the normal source build
instead. The final app link, IPA packaging and device runtime remain unverified.
Apple SDKs and Microsoft runtime binaries are not included in this archive.
