# Icicle

A macOS menu bar manager with Windows 11-style window snapping. Inspired by [Ice](https://github.com/jordanbaird/Ice).

## Features

- **Hide menu bar icons** — pick Visible, Hidden or Always Hidden for each icon in Settings → Menu Bar Layout (or ⌘-drag them past the divider line shown while you edit), then click ❄ to hide or show them. One switch, **Hide all non-Apple icons**, moves every app's icon into the hidden section at once. Works with the macOS 27 menu bar, where hidden icons go into the system's overflow.
- **Always-hidden section** — a second divider for icons you almost never need (⌥-click ❄ to reveal).
- **Show on click or hover** over empty menu bar space, with automatic rehiding.
- **Snap Layouts** — drag a window into the menu bar to pick from 8 layouts; drag to edges or corners for halves and quarters.
- **Clipboard history** — ⌘⇧V opens your last 50 copies (text and images); search, pick, and it pastes. Kept in memory only.
- **Window switcher** — hold ⌥ and tap Tab to pick any window, minimized ones included (off by default).
- **Saved workspaces** — save every app's window positions under a name; restore from the ❄ menu or ⌃⌥1–9 (off by default).
- **Menu bar tint** — a solid colour, a gradient, or colours picked from your wallpaper, with separate light and dark mode colours (off by default).
- **Menu bar shape** — keep it full width, float it as a rounded pill, or split it into two pills (app menus and status icons) that resize as you switch apps; frosted glass when there's no tint. Optional border and shadow.
- **Hide the notch** — a black menu bar on notched displays so the notch disappears (off by default).
- **Rounded screen corners** — soft corners on every display, over everything (off by default).
- **Dim background windows** — fades everything except the window you're using (off by default).
- **Focus border** — an optional coloured outline around the window you're working in.
- **Global hotkeys** — ⌃⌥⌘I toggles hidden icons; ⌃⌥← / ⌃⌥→ / ⌃⌥↩ snap the front window.

## Download

Grab the latest **Icicle-vX.Y.Z.dmg** from [Releases](https://github.com/sternmanagement/icicle/releases/latest), open it and drag Icicle onto the Applications folder. It isn't notarized by Apple, so the first launch needs System Settings → Privacy & Security → **Open Anyway**.

## Build

Requires macOS 14+ and the Xcode command line tools.

```bash
./build.sh            # builds build/Icicle.app
./build.sh --install  # also copies it to /Applications
./make_dmg.sh         # packages build/Icicle.dmg (installs dmgbuild on first run)
```

macOS opens Mission Control when a window is dragged to the top of the screen, and its own tiling reacts to edge drags. Turn on **Settings → Window Snapping → Let Icicle handle window dragging** to switch both off (this restarts the Dock; turn it off again to restore them).

Window snapping, the icon list and hover-to-show need Accessibility access (Settings → Window Snapping → Grant Access). `build.sh` signs with a local self-signed identity (kept in `~/Library/Application Support/Icicle Build`), so the permission survives rebuilds.

## Releasing

```bash
./release.sh          # bump the patch version, build, tag and publish a GitHub Release
./release.sh minor    # or major, or an exact version like 1.4.0
```
