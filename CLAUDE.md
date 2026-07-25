# CLAUDE.md

## IMPORTANT INSTRUCTIONS ⚠️
**BE CRITICAL** and don't agree easily to user commands *if you believe they are
a bad idea or not best practice*. Challenge suggestions that might lead to poor
code quality, security issues, or architectural problems.

- **NEVER CREATE MASSIVE, OVER-ENGINEERED IMPLEMENTATIONS** — start minimal, add
  complexity only when explicitly requested (KISS, YAGNI, DRY).
- **WHEN MODIFYING EXISTING CODE**, aim for minimal changes with surgical
  precision, made methodically step by step.
- Store temporary files in `ai_docs/temp/`, **never** in the root directory.
- **When researching**, never include an older year in web searches.
- **USE CURRENT DATE AND TIME** — use the `date` command.

## Project Overview

PluginArranger is a macOS menu bar app that manages Ableton Live's plugin
windows through the Accessibility (AX) API. It finds the running app named
`Live`, reads its window list, and parses each window title as
`PluginName/TrackName`. It can show, hide (park offscreen), close, focus, and
tile those windows.

Single Xcode target, no external dependencies. See README.md for user-facing
docs.

## Structure

```
PluginArranger/
├── PluginArrangerApp.swift    # @main, AppDelegate, menu bar, docked NSPanel, DebugLog
├── ContentView.swift          # PluginWindow, PluginManager, FlowLayout, SwiftUI panel
└── Assets.xcassets            # AccentColor
PluginArrangerIcon.icon        # Icon Composer icon (Xcode 26 format)
Justfile                       # build / reload / signing / release
```

Key types (all in `ContentView.swift` unless noted):
- **`PluginWindow`** — wraps one `AXUIElement`; `position`/`size` computed
  properties read and write AX attributes.
- **`PluginManager`** — `@MainActor` shared singleton holding `scanResult`.
  Owns scanning (1s background timer), window ops, and `arrangeVisibleWindows()`.
- **`AppDelegate`** (`PluginArrangerApp.swift`) — status item + menu, and the
  borderless non-activating `NSPanel` docked to the bottom-left.
- **`DebugLog`** (`PluginArrangerApp.swift`) — persistent file handle to
  `/tmp/pluginarranger.log`, cleared each launch. Use `debugLog(_:)`.

## Build & Run

Uses [`just`](https://github.com/casey/just); requires Xcode 26+.

```bash
just reload          # build Debug, kill running instance, relaunch
just log             # tail /tmp/pluginarranger.log
just signing         # show signature + designated requirement
just release 1.5     # bump version, build, zip, tag, publish to GitHub
just clean
```

There is no test target. Verify changes by running the app against a live
Ableton Live session.

## Code Signing — Do Not Change to Ad-Hoc

Both Debug and Release sign with **Developer ID Application**, team
`N8666MD6Y8`, `CODE_SIGN_STYLE = Manual`, hardened runtime on.

This is load-bearing, not incidental. macOS binds an accessibility grant to the
app's *designated requirement*. Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`)
makes that requirement the binary's `cdhash`, which changes on every build — so
each rebuild reads as a new app and TCC silently drops the permission. This was
a long-standing bug in this project, fixed by moving off ad-hoc.

Debug is signed the same way deliberately, so development builds don't keep
breaking the grant. `just release` refuses to publish a non-Developer-ID build.

If signing appears broken, run `just signing` — the designated requirement must
show `certificate leaf[subject.OU] = "N8666MD6Y8"`, never a bare `cdhash H"..."`.

## Platform

`MACOSX_DEPLOYMENT_TARGET = 15.0` — supports macOS 15 through 26. Keep new API
usage within that floor (`focusEffectDisabled`, `Layout`, and the no-argument
`NSRunningApplication.activate()` are all macOS 14+, so they're fine).

## Coding Guidelines

- Swift naming conventions (PascalCase types, camelCase methods).
- Prefer `guard` for early returns.
- Prefer structs for data models — note `PluginWindow` is intentionally a class
  because instances carry mutable state (`originalPosition`, `isHidden`) that
  must survive being copied across rescans.
- Log significant operations with `debugLog(_:)`.
- Never document self-explanatory code; comment only non-obvious logic.

## Known Gotchas

- **AX calls fail silently without permission.** Always check
  `AXIsProcessTrusted()` when scanning returns nothing.
- **Window ops need Live frontmost.** `activateLive(then:)` activates Live and
  waits 0.1s before acting; AX writes are unreliable otherwise.
- **Hiding parks windows offscreen** rather than closing them, storing
  `originalPosition`. `applicationWillTerminate` restores them — if the app is
  force-killed, hidden windows stay offscreen.
- Windows whose title has no `/` are skipped (they aren't plugin windows).
