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

        let container = NSView(frame: canvas.bounds)
        container.autoresizingMask = [.width, .height]
        container.addSubview(canvas)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.onTool = { [weak self] tool in self?.canvas.tool = tool }
        toolbar.onAction = { [weak self] name in self?.handleToolbarAction(name) }
        container.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
        ])

        panel.contentView = container
        panel.initialFirstResponder = canvas
    }

    // MARK: - AppDelegate-facing API (kept stable so hotkey wiring barely changed)

    var isShown: Bool { panel.isVisible }

    func isDarkEffective() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// No-op for the native canvas (nothing to pre-warm), kept so AppDelegate's call still compiles.
    func prewarm() {}

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

    func openFile(path: String) {
        autosaveNow()
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let parsed = ExcalidrawIO.parse(data)
        canvas.images = parsed.images
        applyTheme()
        canvas.scene.elements = parsed.elements
        canvas.selection.removeAll()
        canvas.history.clear()
        currentPath = path
        mode = .file
        showOverlay(forScreenUnderCursor: true)
        canvas.recenter()
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
        autosaveNow()
        loadBlank()
        mode = .whiteboard
        showOverlay(forScreenUnderCursor: true)
    }

    private func startFrozen() {
        if mode == .frozen { dismiss(); return }
        autosaveNow()

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        Task { @MainActor in
            guard let cap = try? await Capture.captureUnderCursor(),
                  let img = ExcalidrawIO.decodeDataURL(cap.dataUrl) else { return }
            loadBlank()
            let fileId = "snapshot-\(img.width)x\(img.height)"
            canvas.images[fileId] = img
            var bg = Element(kind: .image)
            bg.x = 0; bg.y = 0; bg.width = cap.logicalW; bg.height = cap.logicalH
            bg.locked = true; bg.fileId = fileId
            canvas.scene.elements = [bg]
            mode = .frozen
            showOverlay(widthPx: cap.widthPx, heightPx: cap.heightPx)
            canvas.recenter()
        }
    }

    private func loadBlank() {
        applyTheme()
        canvas.scene.elements = []
        canvas.scene.scrollX = 0; canvas.scene.scrollY = 0; canvas.scene.zoom = 1
        canvas.selection.removeAll()
        canvas.history.clear()
        canvas.commitTextEditing()
        currentPath = nil
        canvas.needsDisplay = true
    }

    private func dismiss() {
        canvas.commitTextEditing()
        autosaveNow()
        saveTimer?.invalidate()
        mode = .idle
        currentPath = nil
        canvas.scene.elements = []
        canvas.images.removeAll()
        canvas.selection.removeAll()
        panel.orderOut(nil)
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
        autosaveNow()
    }

    // MARK: - Theme / settings

    private func applyTheme() {
        let dark = isDarkEffective()
        canvas.scene.backgroundColor = dark ? "#121212" : "#ffffff"
        canvas.scene.gridEnabled = SettingsStore.gridEnabled
        canvas.strokeColor = dark ? "#ffffff" : "#1e1e1e"
    }

    private func applySettings() {
        guard mode != .idle else { return }
        canvas.scene.gridEnabled = SettingsStore.gridEnabled
        canvas.needsDisplay = true
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.autosaveNow()
        }
    }

    private func hasUserContent() -> Bool { canvas.scene.elements.contains { !$0.locked } }

    private func autosaveNow() {
        saveTimer?.invalidate()
        guard mode != .idle, hasUserContent(),
              let doc = ExcalidrawIO.fileData(canvas.scene, images: canvas.images),
              let png = ExcalidrawIO.exportPNG(canvas.scene, images: canvas.images)
        else { return }

        let base: String
        if let path = currentPath {
            base = (path as NSString).deletingPathExtension
        } else {
            let dir = SettingsStore.resolvedSaveDir()
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            base = "\(dir)/Annotation-\(ts)"
            currentPath = base + ".excalidraw"
        }
        try? doc.write(to: URL(fileURLWithPath: base + ".excalidraw"))
        try? png.write(to: URL(fileURLWithPath: base + ".png"))
        SavedDocuments.prune()
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
