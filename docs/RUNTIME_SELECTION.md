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
checked as packaged artifacts.

An October 5 device log now confirms original-mode loading and JIT on an
iPad16,8 running iPadOS 27.0 (24A5390f). The loaded `Madeira.debug.dylib` UUID,
`636312C6-C8B6-3538-9FC1-8B426F3D87D4`, matches the original release library.
ETS2 starts with DXMT Direct3D 11 at 1280x960 and continues rendering during
roughly 21 minutes of reported play, reaching presentation sequence 40,704.
The earlier null-PC/invalid-RIP startup failure does not recur. A logged
StikJIT detach breakpoint is skipped and execution continues; it is not the
earlier game startup fault. The log does not establish a clean main-process
exit.

Median reported presentation-call gap is 33.3 ms, with occasional stalls
exceeding a second. This is call timing, not independent confirmation of
displayed FPS. Reported memory footprint peaks at 8,992 MB and ends at
8,421 MB. These are an original-mode baseline, not a QoL performance result.

QoL loading/gameplay, MadeiraFX, switching in both directions, profile
preservation and recovery UI still require separate device validation. The
rebuilt PR #2 runtime's ETS2 startup failure remains unresolved; successful
original-mode play does not establish its cause or a fix for the QoL engine.

### QoL return-state candidate fix

Comparing the failing and working logs places the earlier failure before
Direct3D initialization: FEX is asked to execute guest RIP `1`, then branches
to null after rejecting it. All 1,012 packaged Windows guest files in the
failing IPA match the original release, including the game-facing FEX DLL.
Rebuilding that DLL or changing MadeiraFX does not follow from this evidence.

The native Wine fault handler did extend Darwin's `__x[29]` array to access
registers 29, 30 and sometimes 31. Those registers are separate `__fp`, `__lr`
and `__sp` members. Adjacent storage does not make those C array accesses
valid. `ios_arm64_registers.h` now selects the actual member for each register;
instruction data operands retain XZR/WZR's zero/discard behavior. This applies
to signal-context access, Mach instruction emulation and affected register
dumps. The original packaged runtime remains unchanged.

`python3 tests/host/check-arm64-registers.py` runs the actual C emulation
helpers with optimization and bounds sanitizers. It checks FP/LR loads and
stores, pair operations, 32-bit zero extension, SP writeback and XZR. Running
the same harness against the earlier source fails with an out-of-bounds
register access. The rebuilt native handler logs `[arm64-context]
register-members-v1` once during startup to identify this revision.

The rebuild also exposed a build-script dependency on the macOS Wine
configuration enabling GnuTLS. The iOS script now explicitly enables its
statically linked crypto providers, checks their exported function tables and
refuses to archive failed compilations. This repairs fresh-build linking; it
does not explain the already-linked IPA's device startup failure.

This is a verified native bounds fix and a candidate for the compiler-dependent
startup regression, **not a confirmed fix for ETS2**. The logs do not identify
which earlier instruction wrote the invalid guest return address. Device
gameplay with the patched QoL runtime is still needed to resolve that question.
