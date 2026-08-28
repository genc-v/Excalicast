# Excalicast

A native macOS menu-bar app for **screen annotation and whiteboards**, powered by the real
Excalidraw editor. Freeze a screenshot and draw on top, or open an infinite whiteboard — all from
global hotkeys. Native Swift/AppKit shell hosting Excalidraw in a WebView.

## Shortcuts

| Key | Action |
| --- | --- |
| **⌘⇧A** | Annotate the screen (freeze a screenshot) |
| **⌘⇧W** | New whiteboard |
| **⌘⇧O** | Open saved (gallery) |
| **⌘⇧R** | Recenter (or reopen the last document when nothing is open) |
| **⌘⇧`** / **Esc** | Dismiss |

All rebindable in Settings (menu-bar icon → Settings…).

## Highlights

- Full Excalidraw toolset + trackpad pinch-zoom; the overlay floats above the Dock, menu bar, and
  fullscreen apps.
- **Autosaves** every document (`.png` + `.excalidraw`) to `~/Documents/Excalicast`.
- **Gallery (⌘⇧O)**: glass popup below the notch — arrow keys, **Space** to preview, **p** to pin,
  **↩** to open. Pinned items are kept; older unpinned ones auto-delete past the limit (Settings).
- Follows system light/dark; screenshots always stay true-color.

## Build & run

Requires macOS 14+, Xcode Command Line Tools, and Node.

```bash
bash native/build.sh
cp -R native/dist/Excalicast.app ~/Applications/
open ~/Applications/Excalicast.app
```

On first launch, grant **Screen Recording** (System Settings → Privacy & Security), then relaunch.

See [CLAUDE.md](CLAUDE.md) for architecture and internals.
