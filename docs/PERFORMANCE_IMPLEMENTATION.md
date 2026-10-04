# Madeira performance implementation

Specification: [MADEIRA_PERFORMANCE_GOAL.md](MADEIRA_PERFORMANCE_GOAL.md).

## Architecture audit (before implementation)

Audited main `f5b4b4a`: its only change from the previously built application
baseline is the performance specification. The app hosts Wine and FEX in one
process. The library permits one Wine session per app run; changing that would
require a separate wineserver lifetime redesign and is outside this work.

- `LibraryEntry` already persists resolution, pacing, controller bindings, touch
  layouts, opacity and renderer compatibility settings. New profile fields must
  be optional so existing JSON still decodes.
- `MetalHostView` owns the process-lifetime window-level CAMetalLayer. DXMT alone
  owns drawable size. SwiftUI is a geometry/input placeholder; moving rendering
  into SwiftUI previously broke visible frame delivery. Preserve that boundary.
- DXMT's winemetal present thunks are shared by the native D3D9 frontend and
  translated D3D11 calls. They have 30/60 caps and an opt-in absolute-deadline
  limiter. Its present counter includes mailbox work and is not proof of frames
  reaching the display. `presentedTime` has returned zero on this iOS path.
- DXMT already caches compiled shader variants in SQLite. Its sandbox path is
  enabled by default only for WoW64 callers; 64-bit callers can fall through to
  the unavailable Darwin user-cache directory. Reuse this cache, not a second
  shader database. Private `MTLSetShaderCachePath` is not a suitable new API.
- Public Metal binary archives can provide pipeline persistence without that
  private API. Mesh pipelines require separate archive handling.
- D3D11 has an opt-in spatial swapchain, but its scaler initialization asserts
  on allocation failure. Native D3D9 presents through the common Presenter;
  spatial support must preserve gamma, HDR, MSAA and partial-present semantics.
- Changing a CAMetalLayer's drawable size does not change game rendering cost.
  Generic dynamic *internal* resolution requires the game to recreate its
  render targets; do not label presentation resizing as dynamic resolution.
- FEX exposes code-cache APIs, but its current iOS finalization path does not
  implement safe executable allocation/relocation. `LoadCache` reads an
  unvalidated header and advances through variable offsets before range checks.
  The bridge does not register PE sections or supply cache page fault handling.
  Persistent translated-code reuse therefore remains disabled. The FEX
  submodule's `AGENTS.md` prohibits AI code contributions; no FEX edits.
- Hardware HID keyboard mapping, focus-gated key edges, raw mouse deltas,
  pointer lock, wheel/buttons, XInput and editable per-game touch layouts already
  exist and have host tests. A SwiftUI session menu is not a presented UIKit
  controller, so the hardware focus check must explicitly account for it.
- The current metrics overlay derives frame time from a one-second count and
  has no real GPU/onscreen presentation measurements. Add honest timing and
  explicit unavailable/estimated fields; do not claim FPS gains without a game.

## Validation and completion checklist

The phase reports and final checklist below distinguish implemented source,
technical blockers and checks that require an actual device/game.
ETS2 and an iOS device are not present in the Linux build environment. The
reported 20–30 FPS at 1280×960 is the user's baseline, not a measured result here.

## Phase 2 implementation and validation

Phase 2 extends the existing input implementation. The branch now provides:

- Fit and Fill that preserve the actual drawable aspect, explicit Stretch, and
  nearest filtering with integer physical-pixel scaling and aligned origins.
  Presentation and touch mapping share one geometry calculation, including
  unusual resolutions, safe-area offsets and portrait/landscape bounds.
- A backward-compatible per-executable fullscreen preference. Fullscreen uses
  the available surface; disabling it respects UIKit safe-area insets and
  restores the status bar. Safe-area changes refresh the window-level layer.
- Per-executable automatic/manual/disabled mouse capture and sensitivity.
  Automatic capture follows a hidden game cursor on the existing direct-mode
  raw GCMouse path. Manual capture uses Ctrl+Alt+P. Menus, touch editing,
  session exit, backgrounding and disconnection release capture and held
  hardware input. UIKit-only mouse streams retain their existing fallback.
- Existing HID keyboard down/up, modifiers, function/navigation keys, mouse
  buttons/wheel, four-slot XInput and per-game controller mappings are retained.
  Session UI neutralizes controller output even if frontend controller
  navigation is disabled. Touch XInput holds are cleared on focus loss.
- Existing editable per-game touch layouts, size, opacity and action mappings
  are retained. Interrupted keyboard/mouse touch gestures now release their
  old binding, including diagonal sticks, when hidden, remapped, rotated,
  edited or backgrounded; cancellation is idempotent.

Validation: production host tests cover geometry/input agreement, profile JSON
persistence and legacy defaults, HID/PC key maps, focus edge handling, mouse
transport, XInput packet/range/concurrency behavior, touch arbitration and
layout persistence. A new host test executes production touch-release methods
against interrupted keys, mouse buttons, old remaps and diagonal sticks.

Device-only checks remain unverified: actual app/game launch, fullscreen and
safe-area appearance, orientation transitions, physical mouse capture at screen
edges, keyboard shortcuts, physical controller latency and real touch gestures.
No iPad or ETS2 installation is connected to this Linux environment. Automatic
mouse capture follows cursor visibility; generic Wine ClipCursor requests and
virtual-desktop capture are not independently bridged into UIKit pointer lock.
Apple also restricts pointer lock to compatible fullscreen iPad scenes/raw
mouse streams. These constraints must not be presented as universal capture.

The Phase 2 checkpoint did not include the later phases; subsequent work is
reported below.

Phase 2 release validation (2026-10-04): the app and JIT helper compiled and
linked successfully with xtool 1.20.1, Swift 6.3.3 and the iPhoneOS 26.5 SDK on
Linux (122.48 seconds). The changed winemetal and native Presenter objects were
rebuilt against the Phase 2 source before linking; the inactive Phase 3 work
was set aside during validation. Host suites passed: frontend/profile/layout,
hardware input, gamepad transport, touch gamepad, control presets, performance
policy/frame deadlines and interrupted touch input. Existing compiler/linker
warnings remain; no compile error remains in the Phase 2 changes. The unsigned
IPA still needs signing/installing and on-device runtime checks listed above.

## Phase 3 — spatial upscaling

MadeiraFX Off/Quality/Balanced/Performance/Auto requests a lower session monitor
and distinguishes requested game resolution from output. Native and guest
**32-bit and 64-bit local DXMT D3D9/D3D11** now share the host drawable-texture
bridge, including emulated i386 D3D9 and mixed D3D11/D3D9 metadata. It does not
require replacing the verified guest DLLs or extending their Unix-call ABI.

The host stores the renderer's requested layer dimensions. When acquiring a
drawable it reserves a smaller, tracked presentation texture, enlarges only the
real output drawable, and returns the smaller texture through the existing
`MetalDrawable_texture` thunk. Guest viewport state and game resources keep their
original dimensions. Layer property reads also return the renderer's requested
size, preventing a later guest swapchain from inheriting the larger output.
Spatial encoding happens after the original presenter completes gamma/format
conversion and MSAA resolve, on the same command buffer before presentation.

Each layer reuses at most three separately leased texture/scaler pairs. Optional
input texture allocation has an atomic **64 MiB global budget** across layers;
MetalFX's opaque workspace is additional and not included in that bound. No
extra command queue, delayed native frame or temporal history is added. A lease
returns only on GPU completion or destruction of an unsubmitted drawable;
completion and drawable destruction cannot release a reused slot twice.
Pressure purges idle storage and stops new reservations; referenced GPU storage
survives until its users release it. Configuration/dimension changes invalidate
reuse without freeing live game resources.

Unsupported capabilities, HDR/EDR output, non-BGRA8/RGBA8 Unorm formats, allocation
failure and pool/budget exhaustion preserve the renderer's original drawable
size and blit. Once a texture was redirected, an incompatible output usage falls
back to a real renderer scale pass using DXMT's existing compiled Metal library.
Fallback resources are prepared off the main thread before redirection, and the
HUD distinguishes this fallback from active MetalFX. The guest opt-in spatial
swapchain is suppressed to avoid two independent upscalers and its assert path.
A game can still ignore the lower monitor request; smaller presentation storage
alone does not prove reduced game rendering workload.

With diagnostics enabled, the host identifies final-present render encoders by
their drawable texture and observes the color source bound at fragment slot 0.
It reports that **actual game backbuffer**, the presentation input and output
separately; unrelated scene textures are never treated as motion/depth data.
Missing observations remain unavailable. Auto scale advice additionally requires
an observed game backbuffer below output resolution, so a smaller presentation
texture alone cannot qualify as reduced game rendering cost. This color-source
observation also works with Spatial off and preserves legacy pacing.

Phase 3 release compilation/link/package passed (125.00 seconds), with native
winemetal and Presenter rebuilt and unsupported-device resolution fallback
covered by a production profile test. Actual MetalFX image output, texture
usage compatibility and game behavior require device validation.

Live dynamic internal resolution is blocked by the game-owned render targets:
no generic DXMT present callback can make the game recreate them. The adaptive
policy produces bounded, gradual next-launch advice with sustained overload and
headroom windows. It is explicitly not marketed as live DRS. Temporal remains
disabled: no coherent motion vectors, depth, camera jitter or exposure/history
are provided at the common presentation boundary.

## Phase 4 — runtime manager and diagnostics

A session-scoped manager samples once per second only while gameplay is active
and the HUD, explicit Auto mode or interpolation is enabled. The HUD has its own observable
object. Opening UI, backgrounding, launching and disabling all three features stop
the timer and renderer timing callbacks. OS pressure/thermal notifications stay
active for safety; hidden operation has no polling/log stream.

Measurements: submission intervals (128-sample mean/p95/max), command-buffer GPU
time when valid, process CPU time (100% means one core), process footprint,
public available-memory estimate, thermal state and pipeline-creation timing.
Pipeline creation is not reported as a count of shader compilations. Native
submission rate is explicitly estimated; it includes renderer submissions, not
proof of visible frames. Visible FPS requires valid drawable presentedTime;
zero timestamps remain unavailable. Generated encode accounting is separate and
separate from scheduled and timestamp-confirmed generated presentation. CPU/FEX and GPU bottleneck classifications are
estimates; no direct FEX translation-pressure signal exists here.

Auto targets the chosen positive cap or conservative 30 FPS by default. Memory,
serious thermal and Low Power Mode reduce a higher target to 30; sustained
measured headroom is required for recovery, one supported cap at a time. The
scale policy advises 3% steps after 3 seconds of GPU overload or 12 seconds of
headroom, with a 5-second cooldown and user bounds. Advice is used at the next
launch, never to resize live game render targets. Decisions are saved by existing
per-game menu-close/session-finish persistence. Manual pacing disables Auto so
it cannot silently override a user's choice. Compatibility settings are untouched.

Optional pipeline record work is bounded (32 queued descriptors, 2,000 additions
per session); archives are size checked at 256 MiB and writes use temp+rename.
Pressure stops population and releases optional archive/scaler state on a worker.
Ambient artwork has count/cost limits and pressure cleanup. No active game PSO,
Wine allocation or executable FEX page is freed by this manager. Stale on-disk
cache pruning excludes the active DXMT database; its writer still owns its size.

Phase 4 app/helper release build passed (125.54 seconds). Production host tests
cover sampling pause/disable, hidden pressure/cap handling, adaptive cooldowns,
invalid/missing inputs, bounded advice, recovery gates, Auto profile persistence,
and valid/corrupt SQLite cache fallback. Real pressure notifications, GPU timing,
thermal behavior and visual HUD overhead require device validation.

## Phase 5 — experimental optical-flow interpolation

Off remains the default for old and new profiles. MadeiraFX now exposes **2×
(experimental)** and **Auto (experimental)** for local DXMT D3D9/D3D11. This is a
color-only optical-flow backend, separate from MetalFX Spatial and Apple’s
motion/depth-based frame interpolator. MetalFX temporal remains unavailable.

`FrameInterpolation.m` keeps a private previous-color texture per layer and uses
`OpticalFlow.metal` to match image patches in both directions on a 16-pixel grid.
A coarse search plus pixel refinement estimates motion; the midpoint warps the
previous and current colors by half the estimated displacement. Inconsistent or
uncertain pixels retain current color. Whole-frame confidence rejects scene
changes or widespread uncertainty before a synthetic drawable is presented.
This produces a motion-compensated image, rather than counting a repeated native
frame as generation. It can still produce disocclusion, HUD and fast-motion
artifacts, especially beyond the bounded search range.

The shaders execute after the renderer’s original gamma/format conversion and
optional Spatial pass, on its existing command buffer. The authoritative Metal
source is embedded as an exactly matching C string and compiled through public
Metal APIs on the renderer worker; compilation failure preserves native output.
History and generated textures plus flow buffers have a **32 MiB global budget**,
separate from Spatial’s budget. Only SDR BGRA8/RGBA8 Unorm, single-sample output
between 320×240 and 1920×1440 is admitted. No game resources are resized and no
scene depth or game motion vectors are guessed.

Admission requires a fixed native 30 or 60 FPS cap, a panel supporting at least
60 or 120 Hz respectively, three stable one-second samples and measured GPU
headroom. Auto uses stricter headroom and confidence thresholds. Missing timing,
unstable pacing, memory pressure, serious thermal state and Low Power Mode
withdraw admission. Menu, launch and background transitions reset history and
pause synthesis; recovery requires stable samples again. Safety sampling runs
when interpolation is requested even with the HUD hidden. With HUD, Auto and
interpolation all off, no sampling timer runs.

The first frame warms history and retains native presentation. An eligible pair
reserves one additional drawable on the renderer thread. After generation
completes, a presentation-only command buffer on the **same command queue**
blits the generated image and schedules midpoint and native drawables half a
native period apart. This deliberately delays native display by roughly half
a frame (16.7 ms at 30 FPS, 8.3 ms at 60 FPS), plus scheduling overhead. Late,
busy, low-confidence or failed work presents native alone; no catch-up burst
is queued. Acquisition can still wait on the iOS drawable pool; slow acquisition
rejects generation afterward. Actual driver scheduling and latency need device
verification. One layer may have only one interpolation operation in flight.

Native submissions, native confirmed presentations, generated encodes,
generated scheduled presentations and generated confirmed presentations remain
separate. Only a positive drawable `presentedTime` counts as visible; scheduling
or encoding alone never produces a displayed-FPS claim. The HUD reports active,
warmup and named fallback states, plus estimated added display delay.

The existing typed engine reconstruction provider contract remains available
for future motion/depth-aware backends. Its admission and fake-provider tests
cover that contract, not the optical-flow algorithm. The new optical-flow suite
executes the **exact shader core** on CPU texture adapters: translated and static
images, expected warped midpoint, border handling, inconsistent motion,
scene-change confidence, 30/60 FPS deadlines, late-work rejection and Swift
admission/cooldown gates. This validates math and policy; it does **not** execute
Metal’s shader compiler, GPU dispatch, drawable pool or physical display.

## Completion report and checklist

### Fully implemented in source and host-validated

- Backward-compatible per-executable profiles, precise 30/40/60/90/120/unlimited
  producer deadlines, cap transitions and stall recovery without busy waiting.
- Cache namespaces/invalidation and clear UI; corruption fallback for SQLite;
  bounded optional pipeline population and pressure cleanup.
- Shared fullscreen/scaling/input geometry, integer pixel alignment and input
  cancellation; existing keyboard, mouse, controller and touch paths retained.
- Runtime signal collection, estimated bottleneck categories, conservative Auto
  FPS policy, hysteresis/cooldown scale advice, profile decision persistence and
  independently disableable HUD/timing callbacks.
- Typed engine reconstruction provider/input hooks and admission checks.
- Experimental color-based optical-flow matching, midpoint synthesis, history,
  bounded resource reuse, presentation scheduling and separate frame accounting.
  GPU driver and actual displayed output remain device-unverified.

### Partially implemented / runtime-dependent

- MetalFX Spatial is integrated for **local 32/64-bit DXMT D3D9/D3D11**, preserving
  guest viewport state through the host texture bridge. Remote Metal, desktop
  composition and unvalidated D3D12 are excluded. Actual MetalFX images, resource
  usage compatibility and driver/allocation fallback remain device-unverified.
- Renderer persistence uses DXMT's SQLite cache plus public normal render/compute
  Metal archives. Mesh pipelines are not archived by the new hook. Real warm
  launch reuse and pipeline compatibility still need device verification.
- CPU/FEX classification uses aggregate process CPU with GPU/interval signals;
  it does not measure FEX translation time. Pipeline timings include preparation
  and driver work, not a proven shader-compilation count. Native FPS is submission
  rate, explicitly estimated; visible FPS is unavailable without valid iOS
  presentedTime. The diagnostic remote renderer does not support these local
  timing/upscaling hooks.
- Auto scale changes are saved **next-launch recommendations**, not live DRS.
  Auto's target is bounded by the device's supported display caps. No unattended
  compatibility override or speculative FPS boost is used. Interpolation’s
  opt-in display delay and extra presentation buffer are described above.

### Blocked

- **FEX:** current iOS persistent-code load/finalization lacks safe bounded parsing,
  executable allocation/relocation and bridge page registration. Its contribution
  instructions also prohibit AI code changes. Persistent FEX cache stays off.
- **Other presentation paths:** remote Metal, desktop composition, D3D12 and HDR
  upscaling remain excluded. The guest D3D9/D3D11 viewport blocker has been
  removed by the new texture contract, rather than by resizing guest drawables.
- **Live DRS:** game-owned render targets cannot be safely recreated from the
  generic present boundary. Game/renderer cooperation is required.
- **MetalFX temporal / Apple frame interpolator:** trustworthy game motion
  vectors, scene depth, camera jitter and exposure remain absent from the generic
  present interface. The separate color-based optical-flow implementation does
  not remove that engine-data requirement.
- **Device validation:** no connected iOS GPU, iPad or ETS2 workload. Shader driver
  compilation, image quality, actual generated presentation, long-session memory,
  thermals and input/display latency must be measured on hardware.

Changing the virtual monitor's environment while running is insufficient for
live DRS: Wine's session monitor and game-owned targets have independent state.
Sending window-size messages would require a cooperating game and confirmation
that it resized its real render targets. No generic resize request or guessed
depth/motion binding is shipped as a substitute for that cooperation.

### Validation checklist

| Requirement | Evidence / remaining limit |
| --- | --- |
| Build and introduced compiler errors | App/helper full release builds and affected native objects pass; final result recorded below |
| App launch and game launch | Unverified: no connected iOS device or installed Windows game |
| Configuration persistence | Production profile JSON round trips, legacy defaults, Auto decisions and controller/touch layout tests pass |
| Fullscreen enter/exit, safe areas/orientation | Geometry/coordinate tests and cancellation pass; appearance and actual UIKit lifecycle require device |
| Mouse capture/release and keyboard | Focus/edge/PC key maps and interruption tests pass; physical iPad pointer lock and shortcuts require device |
| Controller fallback | Four slots, disconnect/reconnect, signed ranges, packet ABI, concurrent snapshots and neutral UI behavior covered by host tests |
| MetalFX capability fallback | Native/guest/remote/profile admission, texture sizing, atomic global budget and lease release tests pass; actual GPU image/allocation/usage fallback requires device |
| Cache invalidation | Valid SQLite preserved; corrupt DB/journals/locks evicted; unrelated files retained; Metal archive corruption/warm reuse require device |
| HUD completely disabled | Production coordinator test verifies no timer/callback sampling with HUD, Auto and interpolation off, including menu/launch/background pause |
| Frame interpolation | Exact shader core, confidence, timing and admission tests pass; Metal execution, generated images and displayed cadence require device |
| Memory and thermal | Adaptive policy and coordinator pressure tests pass; actual iOS notifications, resident GPU use and long-session behavior require device |
| One profile end-to-end | Host profile persistence, launch environment, virtual monitor and geometry tested; an actual game launch remains unverified |
| ETS2 benchmark | Unavailable: no game/device workload in this environment |

### Benchmark changes

The user's baseline is approximately 20–30 FPS at 1280×960. No after-run FPS,
frame-time, memory, thermal or shader-stutter measurement is available here.
Synthetic deadline/policy tests demonstrate correctness, not gaming performance.
No improvement number is claimed. Test ETS2 on an iPad with the same game scene
and settings, compare cold/warm launch, keep native submissions and visible FPS
separate, and record at least a sustained session for thermal/memory behavior.

### Final build and delivery

The previous five-phase checkpoint's app/helper release build passed in **129.61 seconds** using
xtool 1.20.1, Swift 6.3.3 and the actual iPhoneOS 26.5 SDK on Linux. Affected
native winemetal and Presenter objects were rebuilt. All 13 host suites passed:
frontend/profile/geometry, hardware input, gamepad transport, touch gamepad,
control layouts, input cancellation, frame deadlines/profile migration,
adaptive policy, runtime lifecycle, reconstruction policy, reconstruction
provider contracts, SQLite cache fallback and spatial caller routing. The guest
texture bridge replaces that checkpoint's native-only Spatial routing.

Final edge-case checks cover preserving aspect ratios at minimum internal
dimensions, enforcing the native output target when UIKit display scale already
enlarged the drawable, and gating controller keyboard/mouse emulation with its
input queue's focus state. Unknown guest internal dimensions display as
unavailable. Existing toolchain/baseline warnings remain; no introduced compiler
errors or performance/reconstruction source warnings were found.

The compressed deliverable is `dist/Madeira-performance-unsigned.ipa`, with
adjacent `.build.json` provenance and `.ipa.sha256`. Its packaging verifier checks
ZIP integrity, all 1,075 reference resource hashes, arm64 iOS executable load
commands, deployment targets, executable permissions and bundled dependencies.
The app retains its iOS 17 minimum and the existing JIT helper its iOS 26 minimum.
This is an unsigned package: installation, app/game launch and performance on a
physical device remain unverified. PR #2 contains the implementation review branch;
main was not changed.

### Device checks for the guest Spatial bridge

The guest bridge's final app/helper release build passed in **133.86 seconds**,
including the drawable-reuse correction. The native winemetal and Presenter
objects were rebuilt, and Apple SDK syntax checks found no new source warnings.
All 13 host suites were rerun for this revision. The spatial suite now covers
invalid/aspect-constrained sizes, eight-thread global allocation contention,
idempotent GPU/unsubmitted-frame lease return, shared x86_64/WoW64 thunk routing,
legacy pacing completion and the compiled-library fallback. Host coverage cannot
execute the actual MetalFX driver, shader specialization or iOS drawable pool.

Use a local DXMT D3D9 or D3D11 game entry, keep its normal compatibility settings,
choose output 1280×960 and Quality or Balanced, then launch with the Graphics HUD
field enabled. The game must use the requested lower session resolution; select
it in-game if its saved resolution overrides the monitor. The HUD should show
the actual lower backbuffer, the presentation input, the output and **Spatial
active**. A named fallback or unavailable dimensions are diagnostic results,
not evidence of active MetalFX. Compare the same scene with Spatial Off for
image quality, stable frame time and sustained memory/thermal behavior. Also
exercise menu/background transitions and allocation/format/pressure fallback.
This procedure has not been run here because no iOS GPU or game is connected.

### Testing experimental interpolation

In a local DXMT D3D9/D3D11 game’s MadeiraFX settings choose **2× (experimental)**
and **Precise FPS cap: 30 FPS**, set SDR output to 1280×960 or lower, then relaunch.
Spatial may be enabled independently. Enable the FPS and Graphics HUD fields.
Wait for stable native pacing and inspect the interpolation state. A 20–25 FPS
native workload will remain rejected; interpolation cannot repair those stalls.
Auto uses stricter admission and may stay inactive for scenes accepted by 2×.
For native 60 FPS interpolation the panel must support 120 Hz.

Compare the same scene with interpolation Off. Check moving objects, camera pans,
HUD edges, scene changes and input latency. Exercise menus/backgrounding, native
cap changes, Low Power Mode, thermal/memory pressure and unsupported output.
Generated encodes or scheduled presentations alone do not prove displayed frames;
use confirmed timestamps where available and an external display recording.
No iPad verification or ETS2 performance improvement is claimed by this build.

The interpolation app/helper release build passed in **135.43 seconds** with
xtool 1.20.1, Swift 6.3.3 and the iPhoneOS 26.5 SDK. The affected native renderer
archive was rebuilt first. All **14 host suites** pass, including the new exact
optical-flow core and scheduling/admission tests. Apple SDK syntax checks found
no new warnings in interpolation or performance bridge source. Existing baseline
Swift/linker warnings remain. The unsigned IPA is rebuilt from this revision;
packaging checks its resource hashes, executable architecture and dependencies.

### MadeiraFX eligibility correction

The initial profile gate compared the entire renderer label with a small list.
PE-import detection formats mixed labels as `D3D11 / D3D9`, while installation
scanning formats them as `D3D11/D3D9`. Games can also advertise both DX11 and
OpenGL or DX12. Those labels could incorrectly gray out MadeiraFX on supported
hardware. Eligibility now normalizes each API and admits an entry offering DX9
or DX11, without treating its other renderers as supported. The user must select
Direct3D 9/11; actual effects remain limited to the local DXMT present hooks.
Unknown renderers, desktop composition, remote Metal and entries offering only
unsupported APIs remain excluded. The UI now names the failed check instead of
showing only a generic disabled explanation.

Production profile tests cover spaced labels, DX11 with alternate renderers,
unknown metadata and OpenGL-only exclusion. The renderer scanner and spatial
routing suites also pass. No hardware failure was observed here: the correction
addresses the confirmed metadata bug; iPad diagnostics identify other causes.

The eligibility-fix app/helper release build passed in **129.66 seconds**.
The new regression tests and renderer scanner/spatial suites passed; the PR #2
unsigned bundle is refreshed from this source revision.
