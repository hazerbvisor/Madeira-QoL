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
