# Icicle

A macOS menu bar manager with Windows 11-style window snapping. Inspired by [Ice](https://github.com/jordanbaird/Ice).

## Features

- **Hide menu bar icons** — pick Visible, Hidden or Always Hidden for each icon in Settings → Menu Bar Layout (or ⌘-drag icons left of the `‹` divider), then click ❄ to hide or show them. Works with the macOS 27 menu bar, where hidden icons go into the system's overflow.
- **Always-hidden section** — a second divider for icons you almost never need (⌥-click ❄ to reveal).
- **Show on click or hover** over empty menu bar space, with automatic rehiding.
- **Snap Layouts** — drag a window into the menu bar to pick from 8 layouts; drag to edges or corners for halves and quarters.
- **Clipboard history** — ⌘⇧V opens your last 50 copies (text and images); search, pick, and it pastes. Kept in memory only.
- **Global hotkeys** — ⌃⌥⌘I toggles hidden icons; ⌃⌥← / ⌃⌥→ / ⌃⌥↩ snap the front window.

## Build

Requires macOS 14+ and the Xcode command line tools.

```bash
./build.sh            # builds build/Icicle.app
./build.sh --install  # also copies it to /Applications
```

macOS opens Mission Control when a window is dragged to the top of the screen, and its own tiling reacts to edge drags. Turn on **Settings → Window Snapping → Let Icicle handle window dragging** to switch both off (this restarts the Dock; turn it off again to restore them).

Window snapping, the icon list and hover-to-show need Accessibility access (Settings → Window Snapping → Grant Access). `build.sh` signs with a local self-signed identity (kept in `~/Library/Application Support/Icicle Build`), so the permission survives rebuilds.
