# Madeira Desktop Experience — Ideas & Implementation Roadmap

> Goal: evolve Madeira from a Windows-app/game launcher into a full, efficient Windows-style desktop environment for iPadOS, using the HyperDroid iOS UI as the native shell while keeping Madeira/Wine/FEX/DXMT as the actual runtime.

---

## 1. Core Design Principle

Use **HyperDroid iOS only as the native desktop/UI shell**, not as a second runtime.

Recommended architecture:

```text
Madeira
├── Native Desktop Shell
│   ├── Desktop
│   ├── Taskbar
│   ├── Start menu
│   ├── Search
│   ├── Settings
│   ├── Notifications
│   ├── Widgets
│   ├── File Explorer
│   └── Task Manager
│
├── Madeira Window Manager
│   ├── Wine application windows
│   ├── Minimize / restore
│   ├── Maximize
│   ├── Free resize
│   ├── Focus / Z-order
│   ├── Snap layouts
│   ├── Fullscreen
│   └── Multi-monitor placement
│
├── Madeira Integration Layer
│   ├── App discovery
│   ├── .exe / .lnk launching
│   ├── File associations
│   ├── Recent apps/files
│   ├── Process tracking
│   ├── Prefix/bottle access
│   └── Desktop shortcuts
│
└── Runtime
    ├── Wine
    ├── FEX
    ├── DXMT
    └── Metal / MetalFX
```

The shell should be native SwiftUI/UIKit and largely event-driven. Do not continuously render the desktop when a fullscreen game/app is active.

---

# 2. Performance / Efficiency Requirements

The HyperDroid-derived shell should be lightweight.

## Required optimizations

- Freeze or heavily reduce desktop animations while a fullscreen Wine app/game is active.
- Stop rendering obscured/minimized windows.
- Pause widgets when they are not visible.
- Avoid permanent blur/transparency animation loops.
- Prefer event-driven state updates.
- Allow the desktop shell to idle at a reduced refresh rate when nothing changes.
- Avoid recomputing app lists, file indexes, or process data every frame.
- Cache app icons and metadata.
- Lazy-load Start menu artwork and taskbar thumbnails.
- Suspend browser/media views that are fully hidden.
- Avoid unnecessary background polling.
- Do not run a second simulated desktop/runtime behind Madeira.

Suggested behavior:

```text
Fullscreen game:
Native shell       -> mostly idle
Window manager     -> minimal
Wine/FEX           -> active
DXMT/Metal         -> active

Desktop visible:
Native shell       -> active
Window manager     -> active
Wine/FEX           -> only active apps
DXMT/Metal         -> only visible Windows surfaces
```

---

# 3. HyperDroid iOS Features to Reuse

Keep/reuse the working parts of HyperDroid iOS where possible:

- Windows 11-style desktop layout
- Start menu
- Taskbar
- Search UI
- Window chrome
- Minimize
- Maximize / restore
- Window movement
- Z-order / focus
- Custom wallpaper
- Light/dark themes
- Transparency/glass effects
- Taskbar auto-hide
- Left/center taskbar alignment
- Real iPad battery status
- Real iPad output volume
- Real network connectivity status
- Calendar panel
- File Explorer UI
- Real virtual C: drive mapping
- Back / Forward / Up navigation
- File/folder search
- Create folder
- Rename files/folders
- Delete files/folders
- Share/export files
- Windows 11 cursor support
- Native WKWebView browser
- Browser tabs
- Browser back/forward/address navigation
- Settings UI framework
- Notepad UI

---

# 4. HyperDroid iOS Gaps to Complete

These should be completed before or during Madeira integration.

## Start / Apps

- Replace hard-coded built-in Start apps with real Madeira/Wine installed applications.
- Add functional **All Apps**.
- Add real recent/recommended apps.
- Add recent files.
- Allow pin/unpin to Start.
- Allow Start app reordering.
- Add Start folders/groups.
- Add app rename.
- Add custom app icons.
- Add uninstall/remove options.
- Add app properties.
- Make user/account button functional.
- Make power button functional.

## WebApp Installer

Current installer UI exists but must become functional.

Implement:

- Install button
- Website validation
- Favicon/icon discovery
- Custom icon selection
- App name editing
- Desktop shortcut creation
- Start menu entry creation
- Taskbar pin option
- Remove/uninstall WebApp
- Persistent WebApp registry

## File Explorer

Add:

- Open files instead of ignoring non-directories
- Double-click/tap-to-open
- File associations
- Open With
- Copy
- Cut
- Paste
- Move
- Multi-select
- Drag and drop
- Rename via keyboard shortcut
- Delete confirmation
- Permanent delete
- Properties
- Sorting
- Grouping
- List view
- Details view
- Small/medium/large icons
- Breadcrumb navigation
- Address bar path editing
- Quick Access/Favorites
- Recent files
- Pinned folders
- Recycle Bin
- Archive handling where practical
- File preview pane
- Details pane
- Search subfolders
- Context menus
- Keyboard shortcuts

## Media Apps

### Photos

- Open image from Explorer
- Zoom
- Pan
- Rotate
- Next/previous image
- Metadata
- Fit to window
- Slideshow
- Basic supported image formats

### Music

- Browse real files
- Play/pause
- Seek
- Previous/next
- Volume
- Track metadata
- Album artwork
- Playlist/queue
- Background playback where appropriate

### Video

Add a full video application:

- Open videos from Explorer
- Play/pause
- Seek
- Volume
- Fullscreen
- Subtitle support if practical
- Playback speed
- Hardware-accelerated native playback where possible

## Widgets

The Widgets taskbar button should not be a no-op.

Possible widgets:

- Battery
- CPU
- RAM
- FPS
- GPU/frame time
- Storage
- Calendar
- Clock
- Network
- Recent apps
- Downloads
- Madeira runtime status

---

# 5. Windows 11 Desktop Parity Roadmap

The objective is not to clone every Windows subsystem. The focus should be the parts that make Madeira feel like a real desktop OS.

## 5.1 Window Management

Implement:

- Free edge/corner resizing
- Minimum/maximum window sizes
- Double-click titlebar to maximize
- Drag maximized window to restore
- Aero-style edge snapping
- Snap left/right halves
- Snap thirds
- Snap quarters
- Snap layouts
- Snap Assist
- Snap groups
- Top-of-screen snap bar
- Multi-window same-app support
- Persist window positions/sizes
- Persist maximized state
- Minimize animations
- Restore animations
- Close animations
- Proper focus ordering
- Window shadows
- Active/inactive titlebar states
- Always-on-top capability where useful
- Fullscreen mode
- Borderless fullscreen
- Remember last window geometry per app

## 5.2 Alt+Tab

Add a real Alt+Tab switcher showing:

- Running Wine apps
- Multiple windows of the same app
- Native Madeira windows where appropriate
- Live or cached thumbnails
- Keyboard navigation
- Mouse/touch selection

## 5.3 Task View

Implement:

- Running-window overview
- Window thumbnails
- Close from Task View
- Restore from Task View
- Drag windows between desktops
- Virtual desktop support

## 5.4 Virtual Desktops

Implement:

- Create desktop
- Delete desktop
- Rename desktop
- Switch desktops
- Move window to another desktop
- Per-desktop wallpaper optional
- Persist desktop configuration
- Keyboard shortcuts

---

# 6. Taskbar Improvements

Replace fixed shell behavior with true runtime-aware taskbar behavior.

Implement:

- Dynamic running app icons
- Pin app
- Unpin app
- Reorder pinned apps
- Multiple windows per app
- Window grouping
- Active/running indicators
- Minimized indicators
- Hover/touch previews
- Thumbnail previews
- Click preview to restore
- Taskbar context menus
- Close window
- Close all windows
- Launch new instance
- Pin/unpin
- App properties
- Jump lists
- Recent files
- Recent projects
- Show Desktop button
- Task View button
- Widgets button
- Search mode options
- Left/center alignment
- Auto-hide
- Taskbar size/scaling
- Fullscreen suppression
- Per-monitor taskbar later if multi-monitor is added

---

# 7. Start Menu Improvements

Implement a true Madeira Start experience:

- Pinned apps
- All Apps
- Installed Wine applications
- Installed games
- WebApps
- Madeira utilities
- Search
- Recommended apps
- Recently used apps
- Recent files
- Recently installed apps
- App folders
- Pin/unpin
- Reordering
- App context menu
- Run as different configuration/prefix where relevant
- Open file location
- Uninstall
- Properties
- User/profile menu
- Power/session menu

---

# 8. Search

Current search should become a unified Madeira search.

Search targets:

- Installed Wine apps
- Games
- WebApps
- Files
- Folders
- Settings
- Madeira tools
- Commands
- Recent items

Features:

- Search indexing
- Incremental results
- Best match
- Categories
- File previews
- App previews
- Recent searches
- Search filters
- Open file location
- Run app
- Open Settings page directly

Keep indexing lightweight and incremental.

---

# 9. File Associations

Build a Madeira file-association layer.

Examples:

```text
.exe   -> launch with Wine/FEX
.msi   -> Wine installer
.lnk   -> Madeira/Wine shortcut parser
.bat   -> cmd.exe
.cmd   -> cmd.exe

.png
.jpg
.jpeg
.webp
.bmp   -> Madeira Photos

.mp3
.wav
.flac
.ogg   -> Madeira Music

.mp4
.mov
.mkv
.avi   -> Madeira Video

.txt
.log
.ini
.cfg   -> Notepad / chosen editor

.zip   -> native archive handler
```

Allow the user to change defaults.

---

# 10. Desktop Behavior

Add normal Windows-like desktop interactions:

- Drag desktop icons
- Grid snapping
- Auto-arrange
- Sort by name/type/date
- Selection rectangle
- Multi-select
- Right-click context menu
- New folder
- New shortcut
- New text file
- Paste
- Refresh
- Display settings
- Personalization
- Open terminal here
- Custom icon placement persistence
- Desktop shortcuts generated from installed Wine apps
- Recycle Bin

---

# 11. Notifications

Add a Madeira notification system.

Features:

- Toast notifications
- Notification history
- Notification Center
- App icons
- App name
- Timestamp
- Dismiss
- Clear all
- Per-app enable/disable
- Quiet mode / Do Not Disturb
- Runtime crash notifications
- Download completion
- Install completion
- Update available
- Controller/device connection messages
- Low storage warning
- Wine app error notifications

---

# 12. Quick Settings / System Tray

Use real iPadOS state where APIs allow it, and Madeira-local settings otherwise.

Possible controls:

- Volume
- Audio device info
- Network status
- Bluetooth/device status where available
- Theme
- Night light/display filter
- Performance mode
- Battery
- FPS limiter
- Renderer mode
- Touch controls
- Controller mode
- Mouse capture
- Keyboard mode
- Fullscreen
- Screen scaling
- Madeira runtime controls

Do not fake control over restricted iPadOS settings. Show status or deep-link to iPadOS Settings when direct control is unavailable.

---

# 13. Madeira Task Manager

Build a real Task Manager for the Madeira runtime.

## Processes

Show:

- Wine process
- Executable name
- PID or Madeira process identifier
- App icon
- CPU usage where available
- RAM usage
- Runtime state
- Foreground/background
- Window count
- Prefix/bottle
- Architecture
- FEX status
- DXMT/graphics status

Actions:

- End task
- End process tree
- Bring to front
- Minimize
- Open file location
- Copy process info
- Restart app
- View logs

## Performance

Show:

- Overall CPU usage
- Memory usage
- Madeira memory usage
- GPU/frame timing where accessible
- FPS
- Thermal state
- Battery
- Storage
- DXMT statistics
- FEX statistics
- Active Wine processes

## Startup Apps

Allow:

- Enable/disable startup entries
- Remove startup entries
- Inspect command/path

---

# 14. Run Dialog

Add Win+R-style command launcher.

Examples:

```text
notepad
explorer
cmd
regedit
C:\Games\game.exe
```

Madeira-specific aliases may also be supported:

```text
madeira-settings
madeira-taskmgr
madeira-logs
```

---

# 15. Terminal / Command Prompt

Provide:

- Wine `cmd.exe`
- Optional PowerShell if installed
- Madeira diagnostic terminal
- Copy/paste
- Resizable terminal
- Multiple tabs later
- Launch terminal in current Explorer directory

---

# 16. Settings

Extend Settings with meaningful Madeira functionality.

## System

- Display scale
- Resolution
- External display
- Fullscreen behavior
- Audio
- Notifications
- Power/performance
- Storage

## Bluetooth & Devices

- Mouse behavior
- Pointer speed
- Cursor style
- Mouse capture
- Keyboard shortcuts
- Controller mappings
- Gamepad status
- Touch-control configuration

## Personalization

- Wallpaper
- Theme
- Transparency
- Accent color
- Taskbar
- Start menu
- Desktop icons
- Cursor pack

## Apps

- Installed Wine apps
- WebApps
- Default apps
- File associations
- Startup apps
- App permissions
- Uninstall

## Gaming / Performance

- FPS limiter
- VSync
- Renderer
- DXMT options
- MetalFX options
- Upscaling
- Frame generation if implemented
- Performance profiles
- Background FPS
- Per-game profiles

## Storage

- Prefix/bottle usage
- Game sizes
- Shader caches
- Downloads
- Temporary files
- Logs
- Clear cache

---

# 17. Madeira-Specific Graphics / Gaming Controls

Expose useful Madeira functionality directly in the desktop shell:

- Current renderer
- DXMT status
- Metal status
- MetalFX status
- Resolution
- Render scale
- Upscaling mode
- Frame limiter
- VSync
- Frame pacing
- Background FPS limit
- Mouse capture
- Native keyboard
- Controller mapping
- Touch controls
- Fullscreen
- Borderless fullscreen
- Performance overlay
- Per-game presets

Optional future features:

- Dynamic resolution
- MetalFX spatial scaling
- MetalFX temporal scaling where technically applicable
- Frame interpolation / frame-generation experiments
- FSR-style scaling where applicable

---

# 18. Native Firefox iOS as the Madeira Browser

Madeira should use **Firefox for iOS natively**, integrated into the Madeira desktop shell.

Do **not** run Windows Firefox through Wine/FEX.

The browser path should stay native iOS for performance, memory efficiency, touch support, keyboard/mouse integration, and external-display behavior.

## Architecture

Use the upstream Mozilla Firefox for iOS codebase/components as the basis for Madeira's browser integration.

Target architecture:

```text
Madeira Desktop
├── Native Firefox iOS window
│   ├── Firefox iOS browser UI/components
│   ├── Native Swift/UIKit/SwiftUI integration
│   ├── WKWebView web-content surface
│   ├── Tabs
│   ├── History
│   ├── Bookmarks
│   ├── Downloads
│   └── Firefox account/sync where practical
│
├── Wine/FEX Windows windows
│   ├── Games
│   ├── Windows apps
│   └── Windows utilities
│
└── Madeira Window Manager
    ├── Native-window adapter
    └── Wine-window adapter
```

Firefox should look and behave like a normal Madeira desktop application even though it is a native iOS app internally.

## Important implementation distinction

Firefox for iOS is a native iOS application, but its web-content rendering path uses Apple's WebKit/WKWebView rather than desktop Firefox Gecko.

This is fine for Madeira.

The objective is:

**Firefox iOS browser experience + Madeira desktop window integration + native performance.**

Do not attempt to port desktop Gecko into Madeira as part of this roadmap.

## Source integration

Use the official upstream Firefox iOS repository/components where technically practical.

Prefer reusable upstream modules such as browser/core components rather than copying large amounts of code into Madeira unnecessarily.

Requirements:

- Keep upstream components isolated behind a Madeira browser adapter.
- Preserve upstream license notices.
- Document local modifications.
- Avoid modifying upstream code unless required.
- Keep Madeira-specific window-management code outside upstream Firefox modules where possible.
- Make future upstream Firefox updates reasonably mergeable.
- Review Mozilla branding/trademark requirements before public distribution using official Firefox name/artwork.

## Browser window integration

Firefox must participate in the same Madeira window-management experience as Wine apps.

Implement:

- Native Firefox desktop window
- Free resize
- Minimize
- Maximize / restore
- Fullscreen
- Snap Layouts
- Snap Assist
- Taskbar representation
- Taskbar thumbnail/preview
- Alt+Tab
- Task View
- Z-order/focus
- Window persistence
- External display placement
- Move between iPad and monitor
- Multiple Firefox windows if the integrated Firefox architecture allows it
- Multiple tabs inside Firefox
- Keyboard shortcuts
- Mouse hover/right-click behavior
- Touch behavior

The Madeira window manager must support both:

```text
WindowBackend.nativeIOS
WindowBackend.wine
```

Do not force native Firefox through the Wine rendering path.

## Default browser behavior inside Madeira

Firefox iOS should be Madeira's default browser.

Route these to the native Firefox window:

- `http`
- `https`
- `.html`
- `.htm`
- links opened from Madeira UI
- links opened by native Madeira tools

For links generated inside Wine apps, implement a bridge where practical:

```text
Wine app URL request
        ↓
Madeira URL bridge
        ↓
Native Firefox iOS window
```

If a Wine application explicitly requires Windows shell/browser behavior that cannot be intercepted safely, allow Wine's normal handling as a compatibility fallback.

## Firefox taskbar / Start behavior

Firefox should appear as a first-class installed Madeira application.

Add:

- Start menu entry
- All Apps entry
- Default pinned taskbar entry
- Search result
- Desktop shortcut option
- Pin/unpin
- Recent browser activity where privacy settings permit
- New window action
- New private window action if supported cleanly- Close all Firefox windows

Do not show the old HyperDroid browser as a normal application.

## Downloads integration

Firefox downloads should integrate with Madeira's filesystem experience.

Preferred model:

```text
Native Firefox download
       ↓
Madeira Downloads bridge
       ↓
Visible in Madeira Explorer
```

Requirements:

- Downloads appear in Madeira Explorer.
- Download notifications use Madeira notifications.
- "Show in folder" opens Madeira Explorer.
- Opening downloaded files uses Madeira file associations.
- Download manager remains available inside Firefox.
- Avoid unnecessary duplicate copies of large downloads.

If direct shared storage is not possible for a specific path, use a controlled import/export bridge.

## Upload integration

When a webpage requests a file:

- Allow picking from Madeira's accessible file workspace.
- Expose the active Wine prefix/bottle files through the approved Madeira file bridge where possible.
- Support iPadOS Files picker where useful.
- Do not expose arbitrary inaccessible system paths.

## Browser data

Preserve normal Firefox iOS browser functionality where practical:

- Tabs
- History
- Bookmarks
- Private browsing
- Downloads
- Password/autofill support where upstream permits
- Firefox account/sync where upstream integration remains compatible
- Reader features
- Share actions
- Find in page
- Desktop-site mode

Do not reimplement features already provided well by upstream Firefox unless Madeira desktop integration requires a wrapper.

## Performance requirements

Native Firefox should remain independent of FEX/Wine.

When only Firefox is running:

- Wine/FEX should not be started solely for the browser.
- DXMT should not be involved.
- Firefox should use the native iOS browser rendering path.
- Madeira should not maintain unnecessary Wine background processes.

When a game is fullscreen:

- Firefox windows that are minimized/hidden should reduce work where upstream behavior allows.
- Madeira should avoid continuously generating browser thumbnails.
- Suspend expensive desktop effects behind the fullscreen game.

## External display

Firefox must work in Madeira's external-display modes.

### Desktop monitor mode

```text
External monitor:
- Madeira desktop
- Native Firefox window
- Wine apps
- Explorer
- Taskbar

iPad:
- control deck / touch UI / performance controls
```

### Dual-display mode

Allow Firefox to be placed on either display independently of Wine windows.

Persist preferred display and window geometry where possible.

## Old HyperDroid browser

The current HyperDroid/WKWebView browser UI should not be exposed as a normal browser.

Options:

- remove it from Start/taskbar entirely, or
- retain only a tiny internal web view for Madeira-owned pages such as release notes/help.

Do not maintain two competing user-facing browsers.

## Failure isolation

A Firefox/browser error must not terminate Madeira or Wine apps.

Likewise, a Wine crash must not terminate native Firefox.

Keep browser lifecycle and Wine runtime lifecycle separate.

## Native Firefox acceptance criteria

Browser integration is complete when the user can:

- Open Firefox from Start
- Pin Firefox to the taskbar
- Open normal HTTPS websites
- Open multiple tabs
- Use private browsing
- Download files
- See downloads in Madeira Explorer
- Upload files from Madeira-accessible storage
- Open links from Madeira directly in Firefox
- Open supported URL requests from Wine apps in native Firefox
- Minimize/maximize/resize/snap Firefox like other Madeira windows
- Use Firefox in Alt+Tab and Task View
- Move Firefox to an external display
- Use Firefox without starting Wine/FEX when no Windows apps are running
- Close/reopen Firefox without affecting running Wine applications

---

# 19. App Discovery

Madeira should scan the active Wine prefix/bottle for applications.

Potential sources:

- `Program Files`
- `Program Files (x86)`
- Start Menu shortcut locations
- Desktop shortcuts
- Wine registry uninstall entries
- Known launcher/game directories
- User-added executable paths

Store discovered app metadata:

```text
ID
Display name
Executable
Arguments
Working directory
Icon
Prefix/bottle
Category
Last launched
Launch count
Pinned state
Desktop shortcut state
Taskbar pinned state
```

Do not rescan everything on every frame or every Start-menu opening.

---

# 20. Shortcut System

Support Madeira-native shortcut records and parse Windows shortcuts where practical.

Shortcut capabilities:

- App path
- Arguments
- Working directory
- Icon
- Prefix/bottle
- Environment overrides
- Renderer profile
- Controller profile
- Display profile
- Custom name

Users should be able to create shortcuts from Explorer and the installed-app list.

---

# 21. Multiple App Instances

The current HyperDroid-style controller should not enforce one window per app type.

Allow:

- Multiple Explorer windows
- Multiple browser windows
- Multiple Notepad windows
- Multiple Wine apps
- Multiple windows from one Wine app
- Correct grouping on the taskbar

Window identity should be separate from application identity.

---

# 22. External Display Support

This is a major Madeira feature.

## Mode A — Desktop on External Monitor

```text
iPad display:
- Madeira launcher
- Touch controls
- Settings
- Performance monitor
- Virtual controller

External monitor:
- Full Madeira desktop
- Start
- Taskbar
- Explorer
- Wine apps
- Games
```

This should be the primary "desktop dock" mode.

## Mode B — Windows-Style Dual Monitor

```text
Display 1:
Game / browser / main app

Display 2:
Explorer / Task Manager / secondary apps
```

Requirements:

- Detect connected external display
- Create dedicated window scene on external display
- Independent resolution/layout
- Place Madeira desktop on monitor
- Mouse/keyboard interaction
- Move windows between displays
- Remember per-app monitor preference
- Independent fullscreen
- Correct taskbar behavior
- Optional per-monitor taskbar
- Handle disconnect gracefully
- Move windows back to iPad when monitor disconnects

## Mode C — iPad as Control Deck

When a game is fullscreen on the monitor, iPad can show:

- Touch controller
- Keyboard macros
- FPS/performance
- Volume
- Game controls
- Quick settings
- Screenshots
- Exit/minimize controls

This could become one of Madeira's strongest differentiators.

---

# 23. External Display UX

When a monitor is connected:

1. Detect monitor.
2. Offer or automatically use preferred mode:
   - Mirror
   - Madeira Desktop
   - Extended Desktop
   - Game on Monitor
3. Restore previous monitor configuration.
4. Scale desktop to monitor resolution.
5. Keep iPad UI independent if desired.
6. Route pointer/keyboard appropriately.
7. Avoid rendering duplicate full-resolution game surfaces unnecessarily.

---

# 24. Keyboard and Mouse

Implement strong desktop input support.

## Keyboard

Important shortcuts:

```text
Alt+Tab       -> app/window switcher
Win           -> Start
Win+S         -> Search
Win+E         -> Explorer
Win+R         -> Run
Win+D         -> Show Desktop
Win+I         -> Settings
Win+Tab       -> Task View
Win+Z         -> Snap Layouts
Win+Left      -> Snap left
Win+Right     -> Snap right
Win+Up        -> Maximize
Win+Down      -> Restore/minimize
Ctrl+C/X/V    -> Copy/Cut/Paste
Ctrl+A        -> Select all
Alt+F4        -> Close window
F2            -> Rename
Delete        -> Delete
Shift+Delete  -> Permanent delete
```

## Mouse

- Native pointer
- Mouse capture for games
- Release mouse shortcut
- Right-click
- Double-click
- Hover states
- Scroll
- Drag/drop
- Edge resizing
- Selection rectangles

---

# 25. Touch Support

The desktop must remain usable without mouse/keyboard.

Implement:

- Larger touch hit regions
- Touch-friendly resize handles
- Long-press context menu
- Touch drag/drop
- Touch selection
- On-screen keyboard integration
- Optional GameHub-like touch overlays
- Gesture to reveal taskbar in fullscreen
- Gesture to switch apps

---

# 26. Session / Power Menu

Start-menu power button should control the Madeira runtime, not iPadOS power.

Suggested actions:

- Stop Madeira session
- Restart Wine session
- Close all Windows apps
- Return to Madeira launcher
- Restart desktop shell
- Sleep/suspend runtime where technically safe

Do not pretend to shut down iPadOS.

---

# 27. Runtime Crash Handling

If a Wine app crashes:

- Keep desktop alive
- Remove dead window/taskbar state
- Show crash notification
- Offer relaunch
- Offer logs
- Do not crash the entire Madeira shell

If DXMT/FEX fails:

- Catch error where possible
- Show readable reason
- Offer safe fallback renderer/profile
- Save diagnostics

---

# 28. Updates

Implement a real Madeira update center.

Possible behavior:

- Check GitHub Releases
- Display version
- Display changelog
- Mark updates as:
  - QoL/runtime-data update
  - Requires new IPA
- If update cannot be installed inside the existing IPA:
  - Notify user that a new IPA is required
  - Show changelog
  - Link to release
- Allow update channel:
  - Stable
  - Beta
  - Nightly/Development optional

Do not claim an update was installed if iPadOS signing/reinstallation is required.

---

# 29. Features Not Worth Recreating Literally

Do not spend time cloning Windows components that do not map cleanly to Madeira.

Examples:

- Windows kernel
- Windows Update internals
- Microsoft Defender internals
- BitLocker
- Windows device drivers
- Windows Services architecture
- Windows Boot Manager
- Windows Recovery Environment
- Exact Windows Registry UI unless Wine needs it
- Device Manager unless it can expose meaningful Wine/Madeira devices

Prefer Madeira equivalents.

---

# 30. One-Go Implementation Strategy

This entire roadmap must be implemented as **one continuous Codex workstream**.

Codex must **not stop after each phase and wait for another prompt**. The checkpoints below are internal milestones only.

Continue automatically until the entire roadmap is implemented as far as technically possible.

Only stop early for a genuine hard blocker such as:

- an unavailable external dependency,
- a required Apple capability/entitlement that cannot be provided from source,
- a destructive repository action requiring explicit approval,
- or a technical blocker that makes all remaining work impossible.

Otherwise, continue.

## One-go execution rules

1. Start from the latest target branch.
2. Create/use a dedicated feature branch.
3. Audit Madeira and HyperDroid-iOS architecture first.
4. Reuse existing components wherever practical.
5. Do not pause after planning.
6. Do not ask the user to send `continue`.
7. Maintain a repo TODO/checklist and update it as work completes.
8. Build/test after meaningful integration milestones.
9. Fix compile errors before proceeding.
10. Preserve working Madeira game/runtime paths.
11. Avoid placeholder UI unless its backend is implemented in the same workstream.
12. Do not leave dead buttons or decorative toggles.
13. If something cannot be completed, leave the best working partial implementation, document the blocker, and continue with the rest.
14. Finish with a full integration/build pass.
15. Produce a final implementation report.

## Internal checkpoint A — Real Desktop Foundation

Implement:

- HyperDroid shell integration
- Runtime-aware window registry
- Real Wine app windows
- Multiple instances
- Dynamic taskbar
- Dynamic Start menu
- App discovery
- `.exe` launch
- File associations
- Explorer open/copy/cut/paste
- Free window resizing
- Native Firefox iOS integration/default-browser bridge

Acceptance: boot into Madeira Desktop, discover installed apps, launch multiple Windows apps, launch native Firefox, resize/minimize/maximize windows, and manage real Wine files.

**Continue immediately to checkpoint B.**

## Internal checkpoint B — Windows 11 Multitasking

Implement:

- Snap Layouts
- Snap Assist
- Alt+Tab
- Task View
- Window previews
- Taskbar grouping
- Taskbar pinning/reordering
- Desktop shortcuts
- Right-click menus
- Keyboard shortcuts

**Continue immediately to checkpoint C.**

## Internal checkpoint C — Explorer + Shell Completion

Implement:

- Explorer tabs
- Multi-select
- Drag/drop
- Sorting/views
- Properties
- Open With
- Quick Access
- Recycle Bin
- Search indexing
- Real recent files
- Start folders/recommendations
- Installed Apps settings

**Continue immediately to checkpoint D.**

## Internal checkpoint D — System Tools

Implement:

- Madeira Task Manager
- Run dialog
- Wine CMD
- Notifications
- Notification Center
- Quick Settings
- Startup apps
- Storage management
- App crash handling
- Runtime controls

**Continue immediately to checkpoint E.**

## Internal checkpoint E — Media / Firefox / QoL

Implement:

- Native Firefox iOS desktop integration hardening
- Native Firefox iOS download/upload filesystem bridge
- Native Firefox iOS window/lifecycle integration
- Photos
- Music
- Video
- Widgets
- Clipboard history
- Additional personalization
- Better localization

Do **not** restore the HyperDroid browser as the normal desktop browser.

**Continue immediately to checkpoint F.**

## Internal checkpoint F — External Display

Implement:

- Detect external monitor
- Dedicated Madeira desktop scene
- Game-on-monitor mode
- Dual-display window placement
- Move windows between displays
- iPad control-deck mode
- External-display persistence
- Monitor-disconnect recovery
- Native Firefox iOS external-display support

Acceptance: connect a monitor + keyboard + mouse and use Madeira as a desktop-like Windows gaming/work environment.

**Continue immediately to checkpoint G.**

## Internal checkpoint G — Advanced Desktop

Implement:

- Virtual desktops
- Snap groups
- Advanced Task View
- Per-monitor taskbars
- Multi-monitor window persistence
- Deeper performance controls
- Per-game profiles
- Optional advanced upscaling/frame-generation work

## Final integration pass

Before the task is considered complete:

- Build the complete project.
- Run available tests.
- Fix newly introduced warnings where practical.
- Verify no dead Start/taskbar buttons remain.
- Verify native Firefox iOS is Madeira's default desktop browser.
- Verify the old HyperDroid browser is not exposed as the normal browser.
- Verify app discovery and window-state persistence.
- Verify fullscreen performance leaves the shell mostly idle.
- Verify external-display code safely degrades with no monitor.
- Verify mouse, keyboard, and touch still work.
- Verify existing Madeira game launching still works.
- Verify no credentials, tokens, private paths, or local secrets were committed.
- Write the final implementation report.

---

# 31. Codex Implementation Rules

When Codex implements this roadmap:

1. Do not rewrite Madeira's runtime unless necessary.
2. Keep the desktop shell modular.
3. Keep UI state separate from Wine process state.
4. Do not make the shell depend directly on Wine internals where an abstraction can be used.
5. Keep process/app/window IDs separate.
6. Never assume one app = one window.
7. Do not block the main UI thread with filesystem scanning.
8. Cache icons and application metadata.
9. Preserve fullscreen game performance.
10. Avoid continuous polling where events or notifications can be used.
11. Every new setting should be functional; avoid decorative toggles.
12. Gracefully handle unavailable iPadOS APIs.
13. Never fake control of restricted iPadOS settings.
14. Prefer native SwiftUI/UIKit for the shell.
15. Keep Metal/DXMT rendering separate from shell rendering.
16. Test external display disconnect/reconnect.
17. Preserve touch-only usability.
18. Preserve keyboard/mouse usability.
19. Keep Madeira usable if a child Wine process crashes.
20. Keep work logically organized with clear commits/checkpoints even though this is a one-go implementation.
21. Native Firefox iOS is the user-facing Madeira browser; do not run Firefox through Wine/FEX and do not expose the old HyperDroid browser as the default browser.
22. Keep WKWebView only for internal Madeira embedded-web use.
23. Use official upstream Firefox iOS source/components where practical; preserve required license notices and keep Madeira-specific integration modular.
24. Do not weaken Firefox/iOS security boundaries for convenience; use supported native browser APIs and controlled Madeira bridges.
25. Continue automatically through all internal checkpoints without waiting for another user prompt.
26. The Madeira window manager must support both native-iOS windows and Wine-backed windows through a common abstraction.
27. Native Firefox must never require FEX/Wine merely to browse the web.
28. Keep Firefox browser state/lifecycle isolated from Wine runtime state.

---

# 32. Definition of Success

The long-term goal is:

```text
iPad + Madeira + monitor + keyboard + mouse
                  ↓
A desktop experience where the user can:

- launch installed Windows apps
- browse and manage the Wine filesystem
- multitask with real windows
- snap and resize windows
- use Alt+Tab and Task View
- manage processes
- use Start/search/taskbar normally
- play games fullscreen
- use the iPad as a controller/control deck
- move apps between iPad and external monitor
```

Madeira should feel like a purpose-built **Windows desktop compatibility environment for iPadOS**, not a fake Windows UI layered on top of a game launcher.

---

# 33. Priority Summary

This roadmap is intended to run as **one continuous implementation workstream**.

Internal priority order:

1. HyperDroid shell integration
2. Real Wine app discovery
3. Real Start / All Apps
4. Dynamic taskbar
5. Native Firefox iOS integration/default-browser bridge
6. Free window resizing
7. Multi-window support
8. Explorer file opening + copy/cut/paste
9. File associations
10. Snap Layouts
11. Alt+Tab
12. Task View
13. Task Manager
14. Desktop shortcuts/context menus
15. Search indexing
16. Notifications/system tray
17. Native Firefox iOS integration hardening
18. External-display desktop mode
19. iPad control-deck mode
20. Virtual desktops
21. Functional media/widgets
22. Advanced gaming/performance integration

Codex should continue through all of these without waiting for another prompt.

Final target:

```text
Madeira Desktop
├── Firefox iOS (native browser integrated into Madeira)
├── Explorer
├── Installed Windows apps/games
├── Task Manager
├── CMD / Run
├── Notifications / Quick Settings
├── Snap / Alt+Tab / Task View
└── External monitor + iPad control deck
```

The old HyperDroid browser should **not** appear as the normal desktop browser; native Firefox iOS should be the user-facing browser.