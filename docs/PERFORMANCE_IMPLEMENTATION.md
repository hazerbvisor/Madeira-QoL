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
