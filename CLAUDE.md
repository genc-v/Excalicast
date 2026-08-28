# CLAUDE.md — Excalicast

Guidance for working in this repo.

## What this is

**Excalicast** is a native macOS menu-bar app for **screen annotation + whiteboards**, built on the
real Excalidraw editor. It's a **Swift/AppKit shell** that hosts the `@excalidraw/excalidraw`
React app inside a `WKWebView`. There is no Electron/Tauri — the old Tauri shell was removed.

- Bundle id: `com.excalicast.app` · Accessory (menu-bar) app, no Dock icon.
- Screenshot annotation is done by freezing a ScreenCaptureKit capture as a locked Excalidraw
  image element and drawing on top; whiteboards are a plain infinite canvas.

## Architecture

Two halves talk over a small JS↔native bridge:

- **Native (`native/Sources/excali/*.swift`)**
  - `main.swift` — bootstraps `ExcaliApplication` (accessory policy).
  - `ExcaliApplication.swift` — NSApplication subclass; intercepts trackpad `.magnify` in
    `sendEvent` and forwards to the overlay (pinch-zoom).
  - `AppDelegate.swift` — `NSStatusItem` menu, Carbon global hotkeys, opens Settings/Gallery.
  - `OverlayController.swift` — the `NSPanel` overlay (borderless, non-activating but key-capable,
    `.screenSaver` level, `canJoinAllSpaces|fullScreenAuxiliary`), the `WKWebView`, and the JS
    bridge. **All `invoke` commands are handled here** (`WKScriptMessageHandlerWithReply`), and
    native→JS events go through `emit()` → `window.__excaliEmit`.
  - `Capture.swift` — ScreenCaptureKit screenshot of the display under the cursor.
  - `Gallery.swift` — the Spotlight-style glass popup (grid, Pinned/Recent, Quick Look preview,
    retention/prune, image cache).
  - `Settings.swift` — SwiftUI settings window + shortcut recorder.
  - `SettingsStore.swift` — `UserDefaults` wrapper (hotkeys, grid, maxItems, saveDir, pins).
  - `WebScheme.swift` — serves the built web app over the `excalicast://` scheme.
- **Web (`src/`)** — Vite + React.
  - `annotation/AnnotationOverlay.tsx` — the whole Excalidraw experience (frozen / whiteboard /
    opened-file modes, autosave, export, recenter, Esc handling, prefs persistence).
  - `bridge.ts` — `invoke(cmd,args)` (returns a Promise via the reply handler) and `listen(event)`.
  - `App.tsx` renders only the overlay; Settings is native.

## Build & run

```bash
bash native/build.sh                    # web build + swift build + assemble + codesign
cp -R native/dist/Excalicast.app ~/Applications/   # then relaunch
```

- `build.sh` runs `npm run build`, compiles the Swift executable, assembles
  `native/dist/Excalicast.app`, and **codesigns with `excali-selfsign`** (a self-signed identity in
  `~/Library/Keychains/excali-signing.keychain-db`, password `excali-sign-pw`). The stable identity
  is what keeps the Screen Recording (TCC) grant across rebuilds — don't switch to ad-hoc.
- App icon: `native/makeicon.swift` → `native/AppIcon.icns` (run manually if the icon changes).
- Requires: macOS 14+, Xcode Command Line Tools (Swift 5.9+), Node + npm.

## Conventions / gotchas

- **Bridge command names** are shared strings; adding one means a `case` in
  `OverlayController.handle` and an `invoke("name")` in the web. Args are camelCase.
- **Autosave**: documents write `.png` + `.excalidraw` pairs to `SettingsStore.resolvedSaveDir()`
  (default `~/Documents/Excalicast`); the `.png` doubles as the gallery thumbnail. New docs create
  a file on first change (`save_annotation` returns the path); edits overwrite (`save_to_file`).
- **Retention/pins** live in `SettingsStore`; `pruneSavedFiles()` runs after each save.
- **Canvas theme** follows the system (dark → black canvas + white pen). The Excalidraw canvas is
  always kept in the `light` theme so screenshots don't invert (WebKit lacks the canvas-filter
  Excalidraw uses to counter-invert images).
- **Changing the bundle id resets the Screen Recording grant** (TCC keys by id+signature) — avoid
  unless intended, then `tccutil reset ScreenCapture com.excalicast.app` and re-grant.
- After a rebuild, quit the running app before copying over it: `pkill -f
  "Excalicast.app/Contents/MacOS/Excalicast"`.

## Default shortcuts

⌘⇧A annotate · ⌘⇧W new whiteboard · ⌘⇧O gallery · ⌘⇧R recenter / open last · ⌘⇧` (or Esc) dismiss.
All rebindable in Settings.
