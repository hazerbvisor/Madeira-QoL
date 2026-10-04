# Madeira-QoL Complete Performance Upgrade

This document is the authoritative implementation specification for the Madeira-QoL performance, graphics, fullscreen, and input upgrade.

Codex should treat this file as the source of truth for the project goal. Implement as much as is technically feasible in the current Madeira architecture. Do not stop at planning: inspect the codebase, make the changes, build, test, fix regressions, and document genuine blockers.

Repository: https://github.com/hazerbvisor/Madeira-QoL

## High-Level Goal

Improve Madeira's real-world gaming performance and usability on jailed iOS/iPadOS while preserving the existing FEX + Wine + DXMT architecture and avoiding unnecessary rewrites.

Primary priorities:

1. Stable real frame delivery before synthetic/generated frames.
2. Lower translation and shader overhead.
3. Better frame pacing.
4. Better thermal and memory behavior.
5. Native-feeling fullscreen, mouse, keyboard, controller, and touch input.
6. Apple-native upscaling through MetalFX where technically correct.
7. Per-game performance profiles and diagnostics.

---

# Phase 1 — Core Performance Foundation

## Persistent FEX Cache

Add persistent reuse of FEX translated-code/JIT cache where supported by the current FEX integration.

Requirements:

- Reuse compatible translated blocks between launches.
- Store cache per game/executable when appropriate.
- Handle stale/incompatible cache data safely.
- Never crash because cached translation data is invalid.
- Provide a safe fallback to normal translation.
- Add a way to clear the cache from settings/debug tools.

## Shader and Metal Pipeline Cache

Reduce shader compilation stutter by improving persistence and reuse of renderer caches where supported.

Investigate the current DXMT/Metal pipeline and implement safe persistence of:

- shader compilation results
- Metal pipeline state data where supported
- renderer-side caches exposed by DXMT

Requirements:

- reuse cache between game launches where safe
- invalidate incompatible cache data
- avoid blocking the main UI thread during cache maintenance
- expose a cache-clear option

Do not invent fake caching layers if DXMT or Metal already provides a correct mechanism that can be reused.

## Frame Pacing

Prioritize consistent frame delivery over unstable peak FPS.

Implement or improve:

- frame timing
- presentation cadence
- FPS limiting
- reduction of unnecessary CPU/GPU synchronization
- avoidance of busy-wait loops where possible
- detection/logging of major frame stalls

Supported FPS caps where device/display support them:

- 30 FPS
- 40 FPS
- 60 FPS
- 90 FPS
- 120 FPS
- Unlimited

The limiter should be frame-time aware rather than relying on crude sleep loops when a better timing mechanism is available.

## Memory and Runtime Efficiency

Audit runtime hot paths for avoidable:

- allocations
- copies
- buffer recreation
- synchronization
- cache churn
- background work

Prefer buffer and object reuse where safe.

Respond gracefully to iOS memory pressure.

Avoid large unnecessary resident caches.

---

# Phase 2 — Fullscreen and Native Input

## Fullscreen / Borderless Presentation

Implement a proper fullscreen game presentation mode suitable for iPad.

Requirements:

- game surface uses the available display area correctly
- correct aspect ratio handling
- correct safe-area behavior
- correct orientation behavior
- no accidental UIKit chrome over the rendered game
- preserve compatibility with games requesting unusual resolutions
- avoid stretching unless the user explicitly selects stretch

Supported scaling behaviors should include sensible options such as:

- Fit
- Fill
- Stretch
- Integer/nearest style scaling when technically appropriate

## Native Relative Mouse Input

Implement proper relative mouse input / pointer lock for games.

Goal: when a game captures the mouse, physical movement should continue producing relative motion even when the pointer would otherwise hit the edge of the iPad screen.

Requirements:

- correct capture/release lifecycle
- capture when requested by the game
- release when leaving the game or opening app UI
- avoid permanently trapping the user's pointer
- support sensitivity scaling
- support mouse buttons and wheel input
- preserve compatibility with Wine input paths

## Hardware Keyboard

Improve native hardware keyboard integration.

Requirements:

- proper key-down and key-up events
- modifier handling
- function keys where available
- common PC gaming keys
- avoid duplicate input events
- sensible handling of iPadOS shortcuts while a game owns keyboard focus

## Controllers

Improve gamepad support and XInput mapping.

Requirements:

- map supported Apple GameController devices into the Windows/game input path
- support sticks, triggers, shoulders, face buttons, D-pad, menu/view equivalents
- avoid large input latency
- support per-game mapping overrides if the current architecture makes this practical

## Touch Controls

Add an architecture for optional GameHub-style touchscreen controls.

Support configurable:

- virtual analog sticks
- D-pad
- face buttons
- triggers
- shoulder buttons
- mouse-look region
- tap/click regions
- keyboard-key buttons

Requirements:

- per-game layouts
- editable position and size
- opacity setting
- hide/show toggle
- ability to save layouts

Do not hard-code a single universal overlay.

---

# Phase 3 — MadeiraFX

Create a graphics/performance layer named **MadeiraFX**.

Supported modes:

- Off
- Quality
- Balanced
- Performance
- Auto

## MetalFX Spatial

Integrate Apple MetalFX Spatial upscaling where technically compatible with the current Metal presentation path.

Requirements:

- select a lower internal render resolution
- upscale to the output resolution
- keep UI/configuration explicit about internal vs output resolution
- capability-check MetalFX before enabling it
- disable gracefully on unsupported devices/OS versions

## MetalFX Temporal

Integrate MetalFX Temporal only if Madeira can correctly provide the required inputs.

Do not fake temporal reconstruction.

If the renderer cannot reliably provide motion vectors, depth, jitter, or other required inputs, keep temporal mode disabled and document the blocker.

If support becomes technically possible:

- integrate motion/depth data correctly
- handle camera jitter properly
- avoid severe ghosting
- expose temporal mode only for compatible games/render paths

## Dynamic Resolution Scaling

Implement optional dynamic resolution scaling.

Behavior:

- if frame time exceeds the target for a sustained period, gradually reduce render scale
- if meaningful headroom exists for a sustained period, gradually increase render scale
- avoid rapid oscillation
- enforce user-configurable minimum and maximum render scale
- do not change resolution every frame

Suggested starting ranges:

- Quality: ~0.77-0.90 internal scale
- Balanced: ~0.67-0.77
- Performance: ~0.50-0.67
- Auto: adaptive inside a safe range

These are guidance only; use technically appropriate values for the actual implementation.

---

# Phase 4 — Smart Performance Manager

Create a lightweight runtime performance manager.

Monitor data that is actually available without relying on private APIs unnecessarily.

Useful signals include:

- frame time
- native FPS
- CPU utilization indicators
- renderer/GPU pressure indicators
- memory pressure
- thermal state
- shader compilation stalls
- presentation stalls
- FEX translation pressure where observable

Classify probable bottlenecks into categories such as:

- CPU/FEX limited
- GPU/DXMT/Metal limited
- memory limited
- shader compilation limited
- thermal throttling risk
- mixed/unknown

## Auto Mode

Add an Auto performance mode.

Auto mode may safely tune:

- render scale
- FPS target
- MadeiraFX preset
- background workload
- cache/precompile behavior where applicable

Rules:

- prioritize stable frame time
- do not aggressively boost until the device thermal-throttles
- make changes gradually
- never silently select options known to break compatibility
- persist useful per-game decisions

---

# Phase 5 — Advanced MadeiraFX / Frame Interpolation

Build the architecture for optional frame interpolation.

Modes:

- Off
- 2x
- Auto

Important: real/native rendered FPS and interpolated/presented FPS must always remain distinguishable in diagnostics.

Requirements:

- only enable interpolation when sufficient timing/data/headroom exists
- prioritize latency and artifact prevention over marketing FPS numbers
- automatically disable when frame pacing is too unstable
- automatically disable under severe thermal or memory pressure
- avoid claiming generated frames are native frames

If technically correct frame generation cannot be implemented with the current render path, provide the architecture/hooks and clearly document the blocker rather than shipping a fake implementation.

---

# Per-Game Profiles

Store performance and input settings per executable/game.

Profiles should be persistent across app restarts.

Store where applicable:

- game/executable identifier
- resolution
- render scale
- dynamic resolution toggle
- FPS cap
- MadeiraFX mode
- interpolation mode
- fullscreen/scaling mode
- mouse capture behavior
- mouse sensitivity
- controller mapping
- touchscreen layout
- renderer tweaks
- compatibility overrides

Provide safe defaults for games without a profile.

---

# Performance HUD and Diagnostics

Add an optional low-overhead overlay.

Display where available:

- native FPS
- presented/interpolated FPS
- frame time
- current internal render resolution
- output resolution
- render scale
- MadeiraFX mode
- frame interpolation mode
- CPU/FEX pressure indicator
- GPU/render pressure indicator
- memory pressure
- thermal state
- active FPS cap

Requirements:

- easily disableable
- minimal overhead
- no large logging cost while hidden
- diagnostics must label estimated values as estimates

---

# Benchmark Game — Euro Truck Simulator 2

Use Euro Truck Simulator 2 as an important reference workload.

Observed Madeira-QoL baseline:

- approximately 20-30 FPS
- 1280x960

Primary objective:

Achieve the most stable real ~30 FPS frame delivery possible before enabling interpolation.

Focus specifically on:

- reducing translation-related stalls
- reducing shader compilation stutter
- smoother frame pacing
- reducing unnecessary CPU/GPU synchronization
- dynamic resolution
- MetalFX Spatial where applicable
- stable fullscreen
- proper relative mouse capture
- thermal sustainability during longer sessions

Do not optimize only for ETS2 at the expense of the generic Madeira architecture.

---

# Implementation Rules

1. Audit the existing Madeira-QoL architecture before modifying it.
2. Preserve existing working behavior.
3. Extend existing subsystems rather than rewriting them without evidence.
4. Do not add placeholder UI that pretends unsupported functionality works.
5. Protect optional features with capability checks.
6. Unsupported features must fail gracefully.
7. MetalFX failures must never crash game launch.
8. Keep performance-sensitive work off the main UI thread.
9. Avoid unnecessary private Apple APIs.
10. Keep each subsystem modular.
11. Add useful comments for complex performance code, but avoid excessive comments.
12. Prefer measurable improvements over speculative micro-optimizations.
13. Do not introduce GitHub Actions unless explicitly required.
14. Keep upstream Madeira compatibility in mind because this repository is a fork.
15. Avoid breaking existing Wine, FEX, or DXMT configuration.
16. Do not expose misleading FPS statistics.
17. Keep settings backward-compatible where practical.
18. Add migration/default handling for newly introduced settings.

---

# Build and Validation Requirements

Before declaring the goal complete:

- build the project successfully
- fix compiler errors introduced by the changes
- fix warnings caused by newly added code where practical
- check app launch
- check game launch
- check configuration persistence
- verify fullscreen enter/exit lifecycle
- verify mouse capture/release lifecycle
- verify hardware keyboard input
- verify controller fallback behavior
- verify MetalFX capability fallback
- verify unsupported devices do not crash
- verify caches can be invalidated safely
- verify performance HUD can be fully disabled
- check memory pressure behavior
- check thermal-state handling
- test at least one game profile end-to-end
- use ETS2 as a benchmark when available

If a test cannot be performed in the current environment, state exactly what remains unverified.

---

# Completion Report

At completion, provide a concise implementation report with these categories:

## Fully Implemented
List features completed and working.

## Partially Implemented
List features present but limited by renderer/runtime/platform constraints.

## Blocked
List genuine technical blockers, including the underlying subsystem causing the limitation.

Examples:

- FEX limitation
- Wine limitation
- DXMT limitation
- MetalFX input-data limitation
- iOS/iPadOS API limitation

## Benchmark Changes
Record available before/after measurements, including:

- FPS
- frame-time stability
- resolution/render scale
- memory behavior
- thermal behavior
- shader stutter observations

Never invent benchmark numbers.

---

# Recommended Codex Goal

Use this short goal rather than pasting this entire file into the Goal field:

```
/goal Implement the complete Madeira-QoL performance upgrade described in docs/MADEIRA_PERFORMANCE_GOAL.md.

Treat that document as the authoritative specification and completion checklist. Audit the existing architecture first, implement every feasible requirement, build and test continuously, fix regressions, and continue until all checklist items are complete or a genuine technical blocker is documented.
```
