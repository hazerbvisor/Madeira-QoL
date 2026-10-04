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

For native 32-bit D3D9, MadeiraFX Off/Quality/Balanced/Performance/Auto requests a lower session monitor
and explicitly distinguishes requested internal resolution from output. The
shared native DXMT Presenter encodes public MetalFX Spatial on the same game
command buffer with the existing fence. Scalers are reused by dimension/format,
capability checked and allocation/usage failure falls back to the original blit.
HDR, gamma and MSAA retain the original path. A game can override the requested
monitor; its actual texture dimensions are authoritative. No extra history or
presentation queue is allocated. The upstream opt-in spatial swapchain is
suppressed while this path is requested to avoid double upscaling/asserts.

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
and the HUD or explicit Auto mode is enabled. The HUD has its own observable
object. Opening UI, backgrounding, launching and disabling both features stop
the timer and renderer timing callbacks. OS pressure/thermal notifications stay
active for safety; hidden operation has no polling/log stream.

Measurements: submission intervals (128-sample mean/p95/max), command-buffer GPU
time when valid, process CPU time (100% means one core), process footprint,
public available-memory estimate, thermal state and pipeline-creation timing.
Pipeline creation is not reported as a count of shader compilations. Native
submission rate is explicitly estimated; it includes renderer submissions, not
proof of visible frames. Visible FPS requires valid drawable presentedTime;
zero timestamps remain unavailable. Generated encode accounting is separate and
zero without a real provider. CPU/FEX and GPU bottleneck classifications are
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

## Phase 5 — reconstruction extension contract

The registered-provider boundary accepts coherent native frame pairs, stream
identity, color/motion/depth textures, jitter, exposure and history reset state.
It rejects incompatible dimensions/devices, MSAA output, out-of-range target
times, missing inputs, native rates under 30 FPS, unstable pacing, insufficient
measured GPU headroom and memory/thermal/power pressure. Successful generated
encodes have a separate counter; encoding is never counted as visible or native
presentation. No production backend is registered, so generation and temporal
reconstruction remain disabled. Host tests use fake textures/providers to test
admission and accounting only; they do not synthesize any image.

Phase 5 app/helper release build passed (129.90 seconds). A final native-route
compatibility audit found that guest Presenters do not call the native spatial
bridge; the correction and final rebuild are included in this branch.

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
- Typed reconstruction provider/input hooks and admission checks. No production
  frame-generation backend is registered or advertised as available.

### Partially implemented / runtime-dependent

- MetalFX Spatial works at the source integration boundary for **native 32-bit
  D3D9** only, with `d3d9 = native`, supported device/texture usage and a game
  honoring the requested monitor. Guest D3D11, 64-bit D3D9 and emulated i386 D3D9
  are excluded. Native property updates are tagged per calling thread before
  hopping to UIKit; guest calls keep their original drawable dimensions even
  when layers are shared. Remote Metal's tagged handles are never messaged as
  local Metal objects. Actual image quality/activation remains device-unverified.
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
  compatibility override, extra frame queue or speculative FPS boost is used.

### Blocked

- **FEX:** current iOS persistent-code load/finalization lacks safe bounded parsing,
  executable allocation/relocation and bridge page registration. Its contribution
  instructions also prohibit AI code changes. Persistent FEX cache stays off.
- **Guest DXMT Presenters:** D3D11/64-bit/emulated D3D9 spatial integration needs a
  validated guest DLL/Unix-call bridge change, or a redesigned presentation
  texture contract. Host drawable resizing alone would break the guest viewport.
  Those paths retain original resolution/presentation instead.
- **Live DRS:** game-owned render targets cannot be safely recreated from the
  generic present boundary. Game/renderer cooperation is required.
- **Temporal and interpolation:** motion vectors, depth, camera jitter, exposure,
  coherent previous-frame history and a validated synthesis backend are absent
  from the current common present interface. Off/2x/Auto admission exists as
  architecture/profile data; only Off is effective. The provider contract also
  requires a separate latency/presentation schedule and separate generated-frame
  accounting. No generated image or synthetic FPS gain is shipped.

### Validation checklist

| Requirement | Evidence / remaining limit |
| --- | --- |
| Build and introduced compiler errors | App/helper full release builds and affected native objects pass; final result recorded below |
| App launch and game launch | Unverified: no connected iOS device or installed Windows game |
| Configuration persistence | Production profile JSON round trips, legacy defaults, Auto decisions and controller/touch layout tests pass |
| Fullscreen enter/exit, safe areas/orientation | Geometry/coordinate tests and cancellation pass; appearance and actual UIKit lifecycle require device |
| Mouse capture/release and keyboard | Focus/edge/PC key maps and interruption tests pass; physical iPad pointer lock and shortcuts require device |
| Controller fallback | Four slots, disconnect/reconnect, signed ranges, packet ABI, concurrent snapshots and neutral UI behavior covered by host tests |
| MetalFX capability fallback | Native/guest/remote/profile admission and per-thread sizing tests pass; actual GPU unsupported-device/allocation fallback requires device |
| Cache invalidation | Valid SQLite preserved; corrupt DB/journals/locks evicted; unrelated files retained; Metal archive corruption/warm reuse require device |
| HUD completely disabled | Production coordinator test verifies no timer/callback sampling with HUD and Auto off, including menu/launch/background pause |
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

The final app and JIT helper release build passed in **129.61 seconds** using
xtool 1.20.1, Swift 6.3.3 and the actual iPhoneOS 26.5 SDK on Linux. Affected
native winemetal and Presenter objects were rebuilt. All 13 host suites passed:
frontend/profile/geometry, hardware input, gamepad transport, touch gamepad,
control layouts, input cancellation, frame deadlines/profile migration,
adaptive policy, runtime lifecycle, reconstruction policy, reconstruction
provider contracts, SQLite cache fallback and spatial caller routing.

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
physical device remain unverified. PR #2 contains the complete review branch;
main was not changed.
