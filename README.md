# PluginArranger

A macOS menu bar app for wrangling Ableton Live plugin windows. Scans Live's
open plugin windows via the Accessibility API and lets you show, hide, focus,
close, and auto-arrange them — from the menu bar or a docked panel pinned to
the bottom-left of the screen.

Requires macOS 15 or later (runs on macOS 26).

## Install

Download `PluginArranger-<version>.zip` from the
[latest release](https://github.com/kolywater/plugin-arranger/releases/latest),
unzip, and drag `PluginArranger.app` to `/Applications`.

The app is Developer ID signed but **not notarized**, so macOS quarantines the
downloaded copy and refuses the first launch. Clear it once:

```sh
xattr -dr com.apple.quarantine /Applications/PluginArranger.app
```

(Or right-click the app → **Open** → **Open**, once.) Subsequent launches and
in-place updates are unaffected.

### Grant accessibility permission

PluginArranger can't see Live's windows without it. On first launch it will
prompt; otherwise:

**System Settings → Privacy & Security → Accessibility → enable PluginArranger**

The grant persists across app updates, because every build is signed with the
same Developer ID certificate (see below).

## Updates

After that first install, the app updates itself from GitHub releases. It checks
silently on launch and only speaks up when there's a newer version;
**Check for Updates…** in the menu forces a check and also reports "up to date".

Accepting an update downloads the release zip, verifies it's signed by team
`N8666MD6Y8`, strips quarantine, swaps the bundle, and relaunches. The
accessibility grant carries over — the signing identity doesn't change, so macOS
still recognises the app.

## Usage

Click the `square.stack.3d.up` icon in the menu bar:

- **Refresh** — rescan Live's open plugin windows
- **Show All / Hide All** — restore or park every plugin window
- **Arrange** — tile visible windows in columns across the screen
- Pick a **track** or **plugin** name to focus just those windows
- **Show/Hide docked window** — toggle the bottom-left panel

The docked panel shows the same tracks and plugins as buttons, each with an
eye toggle (hide/show) and an `x` (close). It's resizable from the right edge;
the width is remembered.

Debug output goes to `/tmp/pluginarranger.log` (cleared on each launch).

## Development

Requires [`just`](https://github.com/casey/just) and Xcode 26+.

```
just reload          # build Debug, relaunch
just log             # tail the debug log
just signing         # show signature + designated requirement
just release 1.5     # bump version, build, zip, tag, publish to GitHub
just clean
```

### Why signing matters here

macOS ties an accessibility grant to the app's **designated requirement**. With
ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) that requirement is the binary's
`cdhash`, which changes on every build — so every rebuild looks like a brand
new app and the grant silently stops working.

Both Debug and Release are signed with **Developer ID Application** (team
`N8666MD6Y8`), which produces a team-based requirement that's stable across
rebuilds and certificate renewals:

```
identifier "com.personal.PluginArranger" and anchor apple generic
  and certificate leaf[subject.OU] = "N8666MD6Y8"
```

Debug is signed the same way on purpose — otherwise development builds would
keep breaking the permission. `just release` refuses to publish an app that
isn't Developer ID signed.

Verify at any time with `just signing`.
