# Codemagic native build

Workflow ID: `madeira-unsigned-ios` (display name: **Madeira Debug unsigned IPA**).
It builds the generic arm64 iOS device target in Debug with signing disabled,
then publishes `artifacts/Madeira-QoL.ipa`. Debug preserves the documented
working guest execution configuration. No GitHub Actions or existing IPA is used.

## Runner and external inputs

Use Codemagic's Apple Silicon `mac_mini_m2` runner with its latest Xcode and
Metal Toolchain component. The workflow installs Homebrew build tools and the
Rust iOS target. Enable this repository in Codemagic and select the workflow.

The twelve Microsoft runtime DLLs listed in
[tools/fetch-vcruntime.md](../tools/fetch-vcruntime.md) bootstrap automatically from
Microsoft's official Visual C++ 2015–2022 x64 redistributable **14.44.35211**.
`tools/vcruntime-pins.json` records the immutable download URL, installer SHA-256,
and every staged DLL's SHA-256. `tools/fetch-vcruntime.py` extracts its WiX Burn
cabinets without executing the installer, selects the x64 runtime payload from
the manifest, checks all twelve DLLs, and copies their bytes unchanged. The cached
installer is verified again on every extraction. No private ZIP is needed by default.

Existing private provisioning remains supported. Set either:

- `MADEIRA_VCRUNTIME_DIR`: an existing directory on a privately provisioned runner;
- `MADEIRA_VCRUNTIME_URL` and `MADEIRA_VCRUNTIME_SHA256`: a private downloadable
  ZIP containing those DLLs at its root, and its SHA-256 checksum. Store the URL
  as a secure Codemagic environment variable, especially if it carries credentials.

Explicit overrides are validated as x64 PE DLLs with intact Authenticode payloads;
they do not fall back to a public download if incomplete. Automatic downloads must
also match the pinned per-DLL hashes. Neither installer nor DLLs are committed.

Do not upload a Madeira IPA as an input. The runtime directory is a distinct
Microsoft dependency. These DLLs are ignored by Git and are copied unchanged.

D3D12 is enabled and mandatory in this workflow. The repository already contains
the iOS Metal Shader Converter dylib and public headers; `deps.sh` validates their
pinned hashes. No Apple installer or additional Apple binary is committed by this
change. For an independently provisioned private converter dependency, set
`MADEIRA_MSC_IOS_FILE` to the runner's copy of the same pinned iOS dylib. A missing
or mismatched converter aborts before compilation; CI explicitly sets
`MADEIRA_ALLOW_NO_D3D12=0`. Apple's installer and host converter are unnecessary
for this iOS path. Obtain private inputs under their respective supplier terms.

Signing credentials, an Apple ID and pairing/JIT credentials are unnecessary to
produce this unsigned IPA. They are needed later when installing/running it.

## Precompiled FEX libraries

The default `MADEIRA_USE_PREBUILT_FEX=1` verifies and uses the **seven FEX libraries
already cross-compiled for this branch**, plus their five generated headers. It
skips FEX compilation. The four tracked crypto archives are also reused by
default. Remaining dependencies use verified native caches and compile only on
a cache miss. No completed Wine, DXMT or LLVM iOS archive was produced locally.

`build/fex-ios/prebuilt-pins.json` pins the tracked archive path, archive SHA-256, each file's
SHA-256, FEX revision, recursive dependency revisions and compatibility recipe
hashes. `build/codemagic/fex-prebuilt.py` checks the source revisions and recipe,
validates every bundled file and all 154 ARM64 iOS Mach-O archive objects,
then stages the libraries at the existing Xcode paths. Mismatches fail explicitly.
The bundle includes license notices and provenance. Corresponding source is
available in the pinned recursive submodules and parent build recipe, with
rebuild instructions in `build/fex-ios/prebuilt/README.md`. The bundle has no
Apple SDK or Microsoft runtime binaries.

These archives target `arm64-apple-ios17.0`. They were compiled using Clang 21 and
iPhoneOS 26.5 headers. The already compiled LLVM IR was materialized into normal
Mach-O objects with the same compiler backend, so Xcode need not decode LLVM
bitcode from another compiler version. The final Xcode link and device execution
remain unverified.

Set `MADEIRA_USE_PREBUILT_FEX=0` to build FEX from source instead, including when
changing its revision or compatibility recipe. `MADEIRA_CLEAN_NATIVE=1` removes
staged FEX outputs and restores the verified bundle on the next default build.
The 948 KB compressed bundle is tracked in `build/fex-ios/prebuilt/`, so it is
available in every checkout. Its checksum is checked on every invocation.

## Reusing the remaining native components

`MADEIRA_USE_PREBUILT_CRYPTO=1` reuses the four tracked GnuTLS/GMP/Nettle archives.
Their pinned checksums and all 1,312 ARM64 iOS object members are validated. The
GnuTLS 3.8.9 public headers are staged from the checksum-verified source tarball;
its header template receives the same version and Darwin `iovec` definitions as
upstream configure. No crypto source is compiled. Reading pinned archives from
Git also restores them after `clean-native.sh` deletes the working copies. Set
`MADEIRA_USE_PREBUILT_CRYPTO=0` for a source build instead.

`MADEIRA_REUSE_NATIVE=1` enables a cache for each completed native component under
`toolchains/native-cache`, including Wine headers, FFmpeg, FreeType, ntdll,
wineserver, win32u, combined LLVM/DXMT, Rust pairing and Dock. Each successful
component is saved locally immediately, before the next build stage starts. Libraries,
generated public headers and generated license notices travel together. A
restored FreeType component supplies its own headers without a source clone.

The cache key covers tracked recipe/source contents, submodule revisions and
local tracked edits, dependency keys, Xcode, the iOS SDK and compiler identity.
Rust and objcopy identities are included for their consumers. Changing UI-only
Swift code does not invalidate these native components. Every restored file is
checksum-verified, every archive member must be ARM64 iOS Mach-O, and Dock must
be x86-64 PE. Missing, mismatched or corrupt caches cause that component to rebuild;
incomplete components are never saved. Old configure and `.done` state is removed
before a fresh component build.

Upstream releases provide an IPA, not separate static library archives. Therefore
11 of the project's 20 libraries are available immediately from the checkout;
the remaining nine need their first successful macOS build to populate this cache.
The final app still needs Xcode compilation and linking. Codemagic exports its
cache after a **successful build**, with a 14-day lifetime. The workflow also
publishes `toolchains/native-cache/**/*.tar.gz` as build artifacts, so completed
stages can be recovered from a failed build. It avoids caching the entire LLVM
source/build trees, since the combined DXMT archive is sufficient for reuse.

To restore artifacts from a failed build, set the secure Codemagic variable
`MADEIRA_NATIVE_BUNDLE_URLS` to the download URLs of those component `.tar.gz`
artifacts, one URL per line. URLs may carry credentials and should stay secure.
Each bundle must match this checkout's sources and runner tool identities before
it enters the local cache. Expired artifact URLs must be refreshed. A local copy
can be imported on the matching macOS runner with:

```sh
python3 build/codemagic/native-cache.py import --bundle /path/to/component.tar.gz
```

Previous runs that did not publish these component bundles cannot supply them.
The first build with this workflow still needs to produce the missing components.

Set `MADEIRA_REUSE_NATIVE=0` to bypass native cache restoration.
`MADEIRA_CLEAN_NATIVE=1` also bypasses it, while leaving the cache directory available
for the next normal run. To rebuild every native component from source, set all
three: `MADEIRA_CLEAN_NATIVE=1`, `MADEIRA_USE_PREBUILT_FEX=0` and
`MADEIRA_USE_PREBUILT_CRYPTO=0`.

## Source bootstrap and caches

The recursive submodules select the exact commits recorded in Git. LLVM is fetched
at `8dfdcc7b7bf66834a761bd8de445840ef68e4d1a`, the full revision corresponding to
`8dfdcc7b7` in BUILDING.md. A host `llvm-tblgen` is built first. The pinned LLVM
CMake component graph resolves the transitive dependencies of `passes`,
`bitwriter` and `bitreader`, then only that closure is built for iOS. Optional
zlib, zstd, libxml2 and terminfo dependencies are disabled. Every dependency is mapped to its static component target, including
`LLVMRemarks`; shared C API targets are excluded. The resulting archive
manifest is consumed by DXMT, which creates and indexes a new combined archive
with Apple's `libtool`; objects with identical basenames in different LLVM
archives are preserved. Shader AIR headers are generated from DXMT sources.

When compiling from source, the iOS CMake builds explicitly set
`CMAKE_SYSTEM_PROCESSOR=aarch64` as well as
`CMAKE_OSX_ARCHITECTURES=arm64`. FEX sets `TUNE_CPU=none` and `TUNE_ARCH=generic`, so its Linux-only
`/proc/cpuinfo` and SVE probes are skipped. It always reconfigures, including after
a failed configuration, and uses its pinned bundled dependencies rather than host
Homebrew packages. A parent-repository CMake hook supplies native compatibility
headers only to FEX's `Core.cpp` and `Arm64.cpp`. The pinned fork reads Windows-only
callback/FFS counters, rpmalloc snapshots and Windows memory-region diagnostics
without guarding their consumers. The native archive has no such producers: those
counters stay zero, the disabled allocator has no snapshot, and the region reporter
retains its existing unavailable (`?`) result. Atomic emulation is unchanged and
the pinned FEX submodule is not edited.
Crypto feature macros select the real statically linked iOS GnuTLS paths
independently of the header-generation host's installed libraries. Newly built
crypto archives are staged to the exact app link paths.

Codemagic caches completed native components, llvm-mingw release downloads,
Cargo downloads and ccache. LLVM source and build trees remain available during
a run; the combined archive is cached for later builds. An SDK/Xcode/source recipe change
invalidates LLVM products. No cache is needed for correctness: the scripts stage
the tracked FEX and crypto libraries, then build missing dependencies when
the native cache is empty. llvm-mingw's documented
20260421 tarball is SHA-256 checked on **every** invocation before extraction.
FreeType is fetched at `42608f77f20749dd6ddc9e0536788eaad70ea4b5` (2.13.3).
The tracked GnuTLS/GMP/Nettle and FFmpeg tarballs are checksum verified.

The native build order restores or prepares Wine's host config and required WIDL
headers, stages tracked crypto, restores or builds FFmpeg, stages precompiled FEX
iOS (including JemallocLibs), then restores or builds FreeType, ntdll unix,
wineserver, win32u unix, LLVM/DXMT and the locked Rust pairing library. Dock's
ignored PE resource is also built with llvm-mingw. Existing tracked guest Wine,
FEX and D3D12 PE binaries remain bundled; unused optional WoW64 components are
not compiled as part of the static library bootstrap.

## Archive inventory and early verification

`build/codemagic/native-libraries.json` classifies all 20 `.a` file references
in Madeira.xcodeproj:

| Libraries | Classification | Build source |
| --- | --- | --- |
| FEXCore, FEXCore_Base, JemallocLibs, fmt, cephes_128bit, xxhash, softfloat_3e | prebuilt by default; source build optional | checksum-pinned tracked bundle; `MADEIRA_USE_PREBUILT_FEX=0` builds pinned sources |
| ntdll_unix, wineserver | built from source | pinned Wine with existing Madeira source replacements |
| win32u_unix | generated/composed | pinned Wine plus FreeType 2.13.3 |
| dxmt_combined | generated/composed | pinned DXMT plus pinned LLVM dependency closure |
| avformat, avcodec, swresample, avutil | built from source | tracked FFmpeg 7.1.1 tarball |
| gnutls, hogweed, nettle, gmp | tracked/prebuilt by default; source build optional | pinned tracked archives and release tarballs |
| madeira_rppairing | built from source | Rust source and Cargo.lock |

Source-built/composed rows reuse verified native cache entries when available.
There are no unclassified archive references. The historical tracked
`app/libdxmt_unix.a` is not linked by this Xcode project and is not consumed.
Run `python3 build/codemagic/verify-link-inputs.py --audit` to print the inventory.
Without `--audit`, it fails on every unavailable archive, printing its exact path
and builder, validates archive membership and checks arm64 on macOS. Added or
removed Xcode references also require updating the inventory.

## Clean verification

On macOS, with Xcode and the workflow build tools installed:

```sh
git submodule update --init --recursive
bash build/codemagic/clean-native.sh
# For every component from source, also export both prebuilt flags as 0.
export MADEIRA_CLEAN_NATIVE=1
bash build/codemagic/build-native.sh
python3 build/codemagic/verify-link-inputs.py
```

Set `MADEIRA_CLEAN_NATIVE=1` in Codemagic to perform this deletion after cache
restoration, and bypass native cache reuse. It removes all required native build
trees, including wineserver,
DXMT combined/unix archives, FEX iOS, host/iOS LLVM, FreeType, Wine config,
FFmpeg/GnuTLS outputs and Rust pairing products. It intentionally deletes the
four tracked crypto archives locally. The default then restores their pinned
bytes from Git; disable the crypto prebuilt flag for an actual crypto source build.
Use an empty Codemagic cache for the first validation run; subsequent normal runs
can reuse all verified native components. Native output deletion never alters
tracked source submodule files.

Validation status: recursive checkout and the actual llvm-mingw download/checksum
were verified in Linux. Automatic Microsoft runtime download/extraction was also
executed with an empty download cache and output directory: all twelve DLLs matched
the pinned hashes and retained their x64 architecture and certificate payloads.
Archive audit, missing-input detection and shell syntax were checked there.
A Codemagic run confirmed arm64 GnuTLS/GMP/Nettle and FFmpeg builds, then stopped
at FEX's empty processor configuration, then its Linux-only native CPU probes.
Both configuration blockers are corrected here.
The pinned LLVM host `llvm-tblgen` was compiled and executed on Linux, its 34 static
component targets were resolved using real CMake, and the 47 required Wine headers
were generated by compiling and running the pinned host WIDL. The iOS compilations
of Wine/DXMT/LLVM and the final Xcode link/IPA packaging have **not** completed.
A Linux cross-build with Clang 21, iPhoneOS 26.5 headers and target
`arm64-apple-ios17.0` compiled all seven required FEX static libraries, including
the native diagnostic compatibility headers. All 154 objects were materialized
as ordinary ARM64 iOS Mach-O and packaged with the generated headers. The
importer and archive checks were executed locally. This validates FEX compilation,
not the macOS workflow or
final app link.
The next Codemagic run compiled 36 of 37 ntdll translation units, stopping at a
non-public `rusage_info_v6` page-wait field in `server_ios.c`. That diagnostic now
prints `pgw=n/a`; its two printf-style logging format warnings were also corrected.
The original failure was reproduced locally, then the entire corrected source was
cross-compiled to an ARM64 iOS Mach-O object with Clang 21, iPhoneOS 26.5 headers
and `-Werror=format`. A subsequent Linux build compiled all 37 ntdll files and
linked the complete application. The Codemagic workflow itself still needs a run.

The first xtool attempt rejected the Xcode project because it had no
`Package.swift`. After receiving an Xcode XIP, its Apple certificate chain,
signature and archive checksums were verified, and xtool extracted and installed
the full iPhoneOS 26.5 Darwin Swift SDK. With Swift 6.3.3 and xtool 1.20.1, a
separate SwiftPM staging project then compiled the application's 72 original
Swift/C/Objective-C/Objective-C++ translation units and its JIT helper on Linux.
The source Xcode project was not replaced.

The complete unsigned IPA was linked and packaged on Linux. All 20 linked native
archives passed ARM64 iOS object checks (3,347 objects). This included new source
builds of FFmpeg, FreeType, ntdll, wineserver, win32u, the Rust pairing library,
the pinned LLVM component closure, and all 87 DXMT translation units; FEX and
crypto used the previously verified archives. The final link exposed four
additional wineserver/ntdll global symbol collisions. The existing wineserver
symbol-renaming sweep now isolates those server globals and their references.

Apple's Metal compiler was not executed on Linux. Matching compiled AIR/Metal
shaders and 1,075 packaged resource files were reused from the verified upstream
v0.1.3 IPA (SHA-256
`71e900cbc140778bd6fa67c1062821981ed98e6bfb674d853cfeefd6d242e1c0`). That release
is built from this fork's unchanged application baseline,
`4e9d45a74294cd820120791c4b3f2b79adf4fc70`. Neither upstream application nor
extension executables were used in the new IPA. Bundle IDs, icons, framework
paths, resource hashes, executable permissions, ZIP integrity and ARM64 iOS
Mach-O headers were checked. The app retains iOS 17 as its deployment minimum
and the helper retains iOS 26. No iPhone runtime test was performed.
The prebuilt crypto headers compiled successfully with Wine's bcrypt, secur32
and crypt32 translation units using Clang 21 and iPhoneOS 26.5 headers. All 69
required Wine GnuTLS symbols are present in the tracked archive.
Native reuse checks passed locally, including source/SDK invalidation, dependency
invalidation, corruption rejection, complete restoration of a real ARM64 archive
with headers/notices, and rejection of incomplete components.
This workflow is an unverified build candidate until a Codemagic run completes; it must not be presented as a successful
clean build on the basis of scripts alone.
