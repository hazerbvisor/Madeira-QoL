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

Implementation is in progress. Final phase-by-phase status, exact blockers,
host/build results and device-only checks will be recorded here before the PR.
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

Phases 3–5 remain in progress. They are not part of the Phase 2 completion claim.

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
