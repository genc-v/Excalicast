import AppKit
import SwiftUI

let galleryColumns = 5

/// Observable state for the gallery popup.
final class GalleryModel: ObservableObject {
    @Published var items: [SavedItem]
    @Published var selection = 0
    @Published var previewing = false
    init() { items = SavedDocuments.all() }
    func reload() { items = SavedDocuments.all() }
}

/// Borderless panel that can still become key (for arrow-key navigation).
final class GalleryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the Spotlight-style gallery popup: window lifecycle, placement, and keyboard navigation.
final class GalleryController: NSObject, NSWindowDelegate {
    private var panel: GalleryPanel?
    private var monitor: Any?
    private var model: GalleryModel?
    private let onOpen: (String) -> Void

    init(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
    }

    func show() {
        if let p = panel, p.isVisible { close(); return } // toggle
        close()

        let model = GalleryModel()
        self.model = model
        let view = GalleryView(
            model: model,
            onOpen: { [weak self] path in self?.close(); self?.onOpen(path) },
            onTogglePin: { [weak self] path in
                SettingsStore.togglePin(path)
                self?.model?.reload()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true

        let panel = GalleryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 380),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = hosting
        self.panel = panel

        installMonitor()
        layout(preview: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        removeMonitor()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: - Placement

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Gallery = compact below the notch; preview = large & centered (Quick Look-style).
    private func layout(preview: Bool) {
        guard let panel else { return }
        let vf = currentScreen().visibleFrame
        let (w, h, y): (CGFloat, CGFloat, CGFloat) = preview
            ? (vf.width * 0.82, vf.height * 0.86, vf.midY - vf.height * 0.86 / 2)
            : (880, 400, vf.maxY - 400 - 6)
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: y, width: w, height: h),
                       display: true, animate: false)
    }

    // MARK: - Keyboard navigation

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
    }

    /// Returns true if the key was handled (and should be consumed).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let count = model.items.count
        switch event.keyCode {
        case 49 where count > 0: // space -> toggle preview
            model.previewing.toggle(); layout(preview: model.previewing)
        case 53: // esc -> exit preview, else close
            if model.previewing { model.previewing = false; layout(preview: false) } else { close() }
        case 123 where count > 0: // left
            model.selection = max(0, model.selection - 1)
        case 124 where count > 0: // right
            model.selection = min(count - 1, model.selection + 1)
        case 125 where count > 0: // down
            model.selection = min(count - 1, model.selection + galleryColumns)
        case 126 where count > 0: // up
            model.selection = max(0, model.selection - galleryColumns)
        case 36, 76: // return / enter
            guard count > 0 else { return true }
            let path = model.items[model.selection].excalidrawPath
            close(); onOpen(path)
        case 35 where count > 0: // 'p' -> pin/unpin
            SettingsStore.togglePin(model.items[model.selection].excalidrawPath)
            model.reload()
        default:
            return false
        }
        return true
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
