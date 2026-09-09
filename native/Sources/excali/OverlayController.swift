import AppKit
import CoreGraphics

/// A borderless, non-activating panel that can still become key (for the canvas's keyboard
/// shortcuts) and join other apps' fullscreen Spaces without switching Spaces.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the overlay panel + the native `CanvasView` (which replaced the WKWebView). Handles the
/// annotate / whiteboard / open-file modes, autosave, export, and hotkey actions directly — no JS
/// bridge. The idle app is just the native shell + a tiny empty canvas view.
final class OverlayController: NSObject {
    enum Mode { case idle, frozen, whiteboard, file }

    let panel: OverlayPanel
    private let canvas = CanvasView(frame: .zero)
    private let toolbar = ToolbarView()
    private let zoomControl = ZoomControlView()
    private var toolbarTop: NSLayoutConstraint!

    private var mode: Mode = .idle
    private var currentPath: String?
    private var saveTimer: Timer?

    override init() {
        let frame = (NSScreen.main ?? NSScreen.screens[0]).frame
        panel = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init()
        setupCanvas(frame: frame)
    }

    private func setupCanvas(frame: NSRect) {
        canvas.frame = NSRect(origin: .zero, size: frame.size)
        canvas.autoresizingMask = [.width, .height]
        canvas.onChange = { [weak self] in self?.scheduleAutosave() }
        canvas.onDismiss = { [weak self] in self?.dismiss() }
        canvas.onToolChange = { [weak self] tool in self?.toolbar.highlight(tool) }
        canvas.onZoomChange = { [weak self] z in self?.zoomControl.setZoom(z) }

        let container = NSView(frame: canvas.bounds)
        container.autoresizingMask = [.width, .height]
        container.addSubview(canvas)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.onTool = { [weak self] tool in
            guard let self else { return }
            self.canvas.tool = tool
            self.panel.makeFirstResponder(self.canvas) // keep keyboard shortcuts working after a click
        }
        toolbar.onAction = { [weak self] name in self?.handleToolbarAction(name) }
        container.addSubview(toolbar)

        zoomControl.translatesAutoresizingMaskIntoConstraints = false
        zoomControl.onZoomIn = { [weak self] in self?.canvas.zoomIn() }
        zoomControl.onZoomOut = { [weak self] in self?.canvas.zoomOut() }
        zoomControl.onReset = { [weak self] in self?.canvas.resetZoom() }
        container.addSubview(zoomControl)

        toolbarTop = toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 14)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toolbarTop,
            zoomControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            zoomControl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        panel.contentView = container
        panel.initialFirstResponder = canvas
    }

    // MARK: - AppDelegate-facing API (kept stable so hotkey wiring barely changed)

    var isShown: Bool { panel.isVisible }

    func isDarkEffective() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Warm ScreenCaptureKit at launch so the first ⌘⇧A capture is fast.
    func prewarm() { Capture.prewarm() }

    /// Route the small set of hotkey/menu events to native actions.
    func emit(_ event: String) {
        switch event {
        case "hotkey-frozen": startFrozen()
        case "hotkey-whiteboard": startWhiteboard()
        case "hotkey-recenter": canvas.recenter()
        case "hotkey-dismiss": dismiss()
        case "settings-changed": applySettings()
        default: break
        }
    }

    /// Open a saved document. `restoreCamera` reuses the saved scroll/zoom (for reopening the doc you
    /// were last on); otherwise it centers the content (opening an older doc from the gallery).
    func openFile(path: String, restoreCamera: Bool = false) {
        saveDocument(includePNG: true)
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let parsed = ExcalidrawIO.parse(data)
        canvas.images = parsed.images
        canvas.imageDataURLs = parsed.dataURLs
        applyTheme()
        canvas.scene.elements = parsed.elements
        canvas.selection.removeAll()
        canvas.history.clear()
        currentPath = path
        mode = .file
        showOverlay(forScreenUnderCursor: true)
        if restoreCamera, let c = parsed.camera {
            canvas.setCamera(scrollX: c.scrollX, scrollY: c.scrollY, zoom: c.zoom)
        } else {
            canvas.recenter()
        }
    }

    /// Translate a trackpad magnify into a zoom around the cursor.
    func forwardPinch(_ event: NSEvent) {
        guard panel.isVisible else { return }
        let p = canvas.convert(event.locationInWindow, from: nil)
        canvas.zoom(by: 1 + event.magnification, at: p)
    }

    // MARK: - Modes

    private func startWhiteboard() {
        if mode == .whiteboard { dismiss(); return }
        saveDocument(includePNG: true)
        loadBlank()
        mode = .whiteboard
        showOverlay(forScreenUnderCursor: true)
    }

    private func startFrozen() {
        if mode == .frozen { dismiss(); return }
        saveDocument(includePNG: true)

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        Task { @MainActor in
            guard let cap = try? await Capture.captureUnderCursor() else { return }
            let img = cap.image
            loadBlank()
            let fileId = "snapshot-\(img.width)x\(img.height)"
            canvas.images[fileId] = img
            var bg = Element(kind: .image)
            bg.x = 0; bg.y = 0; bg.width = cap.logicalW; bg.height = cap.logicalH
            bg.locked = true; bg.fileId = fileId
            canvas.scene.elements = [bg]
            mode = .frozen
            showOverlay(widthPx: cap.widthPx, heightPx: cap.heightPx)
            canvas.resetCamera() // screenshot fills the screen exactly at 1:1

            // Encode the dataURL for saving off the main thread — it isn't needed to display.
            DispatchQueue.global(qos: .utility).async { [weak canvas] in
                guard let url = ExcalidrawIO.pngDataURL(img) else { return }
                DispatchQueue.main.async { canvas?.imageDataURLs[fileId] = url }
            }
        }
    }

    private func loadBlank() {
        applyTheme()
        canvas.scene.elements = []
        canvas.images.removeAll()
        canvas.imageDataURLs.removeAll()
        canvas.scene.scrollX = 0; canvas.scene.scrollY = 0; canvas.scene.zoom = 1
        canvas.selection.removeAll()
        canvas.history.clear()
        canvas.commitTextEditing()
        currentPath = nil
        canvas.needsDisplay = true
    }

    private func dismiss() {
        canvas.commitTextEditing()
        saveDocument(includePNG: true) // regenerate the gallery thumbnail on the way out
        saveTimer?.invalidate()
        mode = .idle
        currentPath = nil
        canvas.scene.elements = []
        canvas.images.removeAll()
        canvas.imageDataURLs.removeAll()
        canvas.selection.removeAll()
        panel.orderOut(nil)
        Memory.releaseFreeMemory() // hand freed screenshot/export pages back to the OS
    }

    private func handleToolbarAction(_ name: String) {
        switch name {
        case "new": startWhiteboard()
        case "recenter": canvas.recenter()
        case "copy": copyToClipboard()
        case "save": saveNow()
        case "close": dismiss()
        default: break
        }
    }

    private func copyToClipboard() {
        canvas.commitTextEditing()
        guard let png = ExcalidrawIO.exportPNG(canvas.scene, images: canvas.images),
              let image = NSImage(data: png) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        dismiss()
    }

    private func saveNow() {
        canvas.commitTextEditing()
        saveDocument(includePNG: true)
    }

    // MARK: - Theme / settings

    private func canvasIsDark() -> Bool {
        switch SettingsStore.theme {
        case .light: return false
        case .dark: return true
        case .auto: return isDarkEffective()
        }
    }

    private func applyTheme() {
        let dark = canvasIsDark()
        canvas.scene.backgroundColor = dark ? "#121212" : "#ffffff"
        canvas.scene.gridEnabled = SettingsStore.gridEnabled
        canvas.strokeColor = dark ? "#ffffff" : "#1e1e1e"
        canvas.strokeWidth = CGFloat(SettingsStore.strokeWidth)
    }

    private func applySettings() {
        guard mode != .idle else { return }
        let dark = canvasIsDark()
        canvas.scene.backgroundColor = dark ? "#121212" : "#ffffff"
        canvas.scene.gridEnabled = SettingsStore.gridEnabled
        canvas.strokeColor = dark ? "#ffffff" : "#1e1e1e"
        canvas.strokeWidth = CGFloat(SettingsStore.strokeWidth)
        canvas.needsDisplay = true
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        saveTimer?.invalidate()
        // During active editing, persist only the tiny vector .excalidraw — the (expensive, full-res)
        // .png thumbnail is regenerated only on dismiss/save/copy.
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.saveDocument(includePNG: false)
        }
    }

    private func hasUserContent() -> Bool { canvas.scene.elements.contains { !$0.locked } }

    /// Write the document off the main thread so opening/switching never blocks on a full-res PNG
    /// export. The `.excalidraw` (vector, cheap — cached screenshot dataURL) always writes; the
    /// `.png` (gallery thumbnail / shared image) only when asked.
    private func saveDocument(includePNG: Bool) {
        saveTimer?.invalidate()
        guard mode != .idle, hasUserContent() else { return }

        let base: String
        if let path = currentPath {
            base = (path as NSString).deletingPathExtension
        } else {
            let dir = SettingsStore.resolvedSaveDir()
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            base = "\(dir)/Annotation-\(ts)"
            currentPath = base + ".excalidraw"
        }
        // Snapshot value types so the background write is race-free even if the scene is cleared next.
        let scene = canvas.scene
        let images = canvas.images
        let dataURLs = canvas.imageDataURLs
        DispatchQueue.global(qos: .utility).async {
            if let doc = ExcalidrawIO.fileData(scene, images: images, dataURLs: dataURLs) {
                try? doc.write(to: URL(fileURLWithPath: base + ".excalidraw"))
            }
            // Small preview for the gallery — full-fidelity data lives in the .excalidraw.
            if includePNG, let png = ExcalidrawIO.exportPNG(scene, images: images, maxDimension: 1400) {
                try? png.write(to: URL(fileURLWithPath: base + ".png"))
            }
            SavedDocuments.prune()
        }
    }

    // MARK: - Window placement

    private func showOverlay(forScreenUnderCursor: Bool) {
        showOverlay(screen: Capture.screenUnderCursor())
    }

    private func showOverlay(widthPx: Int, heightPx: Int) {
        let matches = NSScreen.screens.filter {
            Int(($0.frame.width * $0.backingScaleFactor).rounded()) == widthPx
                && Int(($0.frame.height * $0.backingScaleFactor).rounded()) == heightPx
        }
        showOverlay(screen: matches.count == 1 ? matches[0] : Capture.screenUnderCursor())
    }

    private func showOverlay(screen: NSScreen) {
        // Push the top toolbar below the notch / menu-bar safe area so it isn't clipped.
        toolbarTop.constant = max(14, screen.safeAreaInsets.top + 8)
        panel.setFrame(screen.frame, display: true)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        canvas.needsDisplay = true
    }
}
