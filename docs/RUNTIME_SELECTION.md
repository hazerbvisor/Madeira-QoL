# Original Madeira and Madeira-QoL runtime selection

The dual-runtime IPA defaults to **Original Madeira**. At each cold start a
runtime picker shows the active build. Choose Original (QoL Off) or Madeira-QoL
(On). If you change the choice, swipe Madeira away in the app switcher and open
it again. The QoL interface also has **Settings → Runtime → Use Madeira-QoL**.
The original mode uses the original interface as well as its runtime. The
startup picker lets you return to QoL without reinstalling.

This is a process-wide choice, not a per-game effect setting. The launcher
loads exactly one complete app library before calling its main entry point.
It never changes engines within a process or silently falls back to another
engine after a loading error. Restarting also discards the old JIT/runtime
state. Enable JIT again normally when needed.

## What “original” means

`Madeira.debug.dylib` comes byte-for-byte from the published
[Madeira v0.1.3 IPA](https://github.com/willfaust/Madeira/releases/download/v0.1.3/Madeira-0.1.3.ipa).
The source is upstream commit `4e9d45a74294cd820120791c4b3f2b79adf4fc70`.
The pinned IPA SHA-256 is
`71e900cbc140778bd6fa67c1062821981ed98e6bfb674d853cfeefd6d242e1c0`.
Packaging rejects any other baseline. The original JIT helper, frameworks,
guest DLLs and resources are retained. The launcher and main Info.plist are
replaced, the QoL library is added, and stale bundle signature directories and
provisioning profiles are removed for sideload signing. Original mode is not
the earlier Linux diagnostic rebuild.

The rebuilt SwiftUI app, Wine, FEX and DXMT are linked into `MadeiraQoL.dylib`.
The launcher contains none of those implementations and has no load dependency
on either app library. Only the selected library publishes the symbols Wine
needs through `RTLD_DEFAULT`; `RTLD_FIRST` scopes the entry lookup to that
library on Apple platforms. A load error shows a recovery picker and requires
a restart, avoiding duplicate Swift/Objective-C types and native global state.

Optional verified Microsoft runtime DLLs live in `qol-x86_64-vcruntime/`. Only
the QoL app uses that overlay. The original `x86_64-vcruntime/` directory is
retained unchanged from the release. Existing DLLs already installed in the
shared Wine prefix remain there; the selector does not reset the prefix.

Both modes share Documents, games, saves and ordinary library settings. Before
switching into original mode, the launcher saves QoL-owned `performanceUpgrade`
and `metadataRevision` fields in `madeira-qol-profiles.json`. It restores those
fields by entry ID when returning to QoL, while preserving shared settings
changed in original mode and leaving deleted games deleted. This sidecar does
not migrate game save formats or repair an unreadable library. Selection is
stored in `Documents/madeira-runtime.txt`: `original` or `qol`. Deleting the file
or using an unrecognized value selects original at the next cold start.

## Build and package

Finish the ordinary xtool release build first; do not modify app sources while
it runs. Then run, with the appropriate Swift/Clang iOS toolchain configured:

```sh
python3 tools/build-runtime-selector.py \
  --build-yaml /path/to/MadeiraLinux/.build/release.yaml \
  --clang /path/to/ios-clang \
  --output-dir /path/to/runtime-binaries

python3 tools/package-runtime-selector.py \
  --original-ipa /path/to/Madeira-0.1.3-upstream.ipa \
  --binaries /path/to/runtime-binaries \
  --vcruntime /path/to/verified-Microsoft-runtime-files \
  --output dist/Madeira-dual-runtime-unsigned.ipa

python3 tests/host/check-runtime-selector.py
```

`--vcruntime` is optional; when provided, the existing runtime verifier must
accept the files. The package builder verifies Mach-O type, architecture,
platform, main entry points, launcher isolation, ZIP integrity and preservation
of original files. It writes a manifest and build/checksum reports. The IPA
needs sideload signing, including both app dylibs and the original helper.
The ordinary Codemagic workflow still produces the single-runtime app; this
packaging step is required to add the selector.

## Validation limits

Host tests verify that only the chosen runtime initializes, that Wine's global
symbol lookup resolves that runtime, and that failed loading/entry lookup never
initializes a replacement. Both iOS libraries and the launcher are compiled and
checked as packaged artifacts. Apple dyld loading, the startup picker, profile
preservation, JIT and ETS2 must still be verified on an iPad after signing.
This feature provides an actual original-runtime option; it is not evidence
that the unresolved PR #2 ETS2 crash has been fixed.
