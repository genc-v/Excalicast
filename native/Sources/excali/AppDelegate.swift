import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let hotkeys = HotkeyManager()
    private var settingsController: SettingsController?
    private var galleryController: GalleryController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for Screen Recording up front (macOS applies it after a relaunch).
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        setupMainMenu()
        setupStatusItem()
        registerHotkeys()

        // Route trackpad pinch (magnify) events to the overlay for Excalidraw zoom.
        ExcaliApplication.onMagnify = { [weak overlay] event in overlay?.forwardPinch(event) }

        // Pre-warm the WebView (mount Excalidraw hidden) so the first annotate is instant. Deferred
        // so it doesn't compete with launch or the Screen Recording prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak overlay] in
            overlay?.prewarm()
        }
    }

    /// A standard Edit menu so ⌘X/⌘C/⌘V reach the WebView as cut:/copy:/paste: — required for
    /// pasting an image into the canvas with ⌘V (otherwise only right-click → Paste works).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Excalicast",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "pencil.tip.crop.circle",
                accessibilityDescription: "Excalicast"
            )
        }
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Annotate Screen", action: #selector(annotate), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "New Whiteboard", action: #selector(whiteboard), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Open Saved…", action: #selector(openGalleryMenu), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Excalicast", action: #selector(quit), keyEquivalent: "q"
        ).target = self
        statusItem.menu = menu
    }

    // MARK: - Hotkeys

    func registerHotkeys() {
        hotkeys.unregisterAll()
        hotkeys.register(id: 1, hotkey: SettingsStore.annotate) { [weak self] in
            self?.overlay.emit("hotkey-frozen")
        }
        hotkeys.register(id: 2, hotkey: SettingsStore.recenter) { [weak self] in
            guard let self else { return }
            // While a document is open, recenter it; otherwise reopen the last one worked on.
            if self.overlay.isShown {
                self.overlay.emit("hotkey-recenter")
            } else if let path = SavedDocuments.newestPath() {
                // Reopening the doc you were last on restores where you were looking.
                self.overlay.openFile(path: path, restoreCamera: true)
            }
        }
        hotkeys.register(id: 3, hotkey: SettingsStore.dismiss) { [weak self] in
            self?.overlay.emit("hotkey-dismiss")
        }
        hotkeys.register(id: 4, hotkey: SettingsStore.whiteboard) { [weak self] in
            self?.overlay.emit("hotkey-whiteboard")
        }
        hotkeys.register(id: 5, hotkey: SettingsStore.openGallery) { [weak self] in
            self?.openGallery()
        }
    }

    // MARK: - Actions

    @objc private func annotate() { overlay.emit("hotkey-frozen") }

    @objc private func whiteboard() { overlay.emit("hotkey-whiteboard") }

    @objc private func openGalleryMenu() { openGallery() }

    private func openGallery() {
        if galleryController == nil {
            galleryController = GalleryController(onOpen: { [weak self] path in
                self?.overlay.openFile(path: path)
            })
        }
        galleryController?.show()
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsController(onChanged: { [weak self] in
                guard let self else { return }
                self.registerHotkeys()
                self.overlay.emit("settings-changed")
            })
        }
        settingsController?.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
