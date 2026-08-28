import AppKit
import ImageIO
import SwiftUI

/// Decode a downsampled thumbnail (fast) and cache it, so grid rendering and Quick Look
/// navigation don't re-decode full-resolution Retina PNGs on every keypress.
private let imageCache = NSCache<NSString, NSImage>()

func downsampledImage(path: String, maxPixel: CGFloat) -> NSImage? {
    let key = "\(path)@\(Int(maxPixel))" as NSString
    if let cached = imageCache.object(forKey: key) { return cached }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        return nil
    }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        return nil
    }
    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    imageCache.setObject(img, forKey: key)
    return img
}

struct SavedItem: Identifiable {
    let id = UUID()
    let excalidrawPath: String
    let previewPath: String?
    let name: String
    let date: Date
    let pinned: Bool
}

/// Saved `.excalidraw` files (with sibling `.png` previews). Pinned first, then newest first.
func loadSavedItems() -> [SavedItem] {
    let dir = SettingsStore.resolvedSaveDir()
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
        at: URL(fileURLWithPath: dir),
        includingPropertiesForKeys: [.creationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    let items = urls
        .filter { $0.pathExtension == "excalidraw" }
        .map { url -> SavedItem in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? Date.distantPast
            let png = url.deletingPathExtension().appendingPathExtension("png")
            let preview = fm.fileExists(atPath: png.path) ? png.path : nil
            return SavedItem(
                excalidrawPath: url.path,
                previewPath: preview,
                name: url.deletingPathExtension().lastPathComponent,
                date: date,
                pinned: SettingsStore.isPinned(url.path)
            )
        }
    let pinned = items.filter { $0.pinned }.sorted { $0.date > $1.date }
    let recent = items.filter { !$0.pinned }.sorted { $0.date > $1.date }
    return pinned + recent
}

/// Path of the most recently modified saved `.excalidraw` (the last one worked on).
func newestSavedPath() -> String? {
    let dir = SettingsStore.resolvedSaveDir()
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
        at: URL(fileURLWithPath: dir),
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
    return urls
        .filter { $0.pathExtension == "excalidraw" }
        .max(by: { mtime($0) < mtime($1) })?
        .path
}

/// Delete oldest non-pinned saved items beyond the retention limit.
func pruneSavedFiles() {
    let max = SettingsStore.maxItems
    guard max > 0 else { return }
    let nonPinned = loadSavedItems().filter { !$0.pinned } // already newest-first
    guard nonPinned.count > max else { return }
    let fm = FileManager.default
    for item in nonPinned.suffix(nonPinned.count - max) {
        try? fm.removeItem(atPath: item.excalidrawPath)
        if let p = item.previewPath { try? fm.removeItem(atPath: p) }
    }
}

private let galleryColumns = 5

final class GalleryModel: ObservableObject {
    @Published var items: [SavedItem]
    @Published var selection = 0
    @Published var previewing = false
    init() { items = loadSavedItems() }
    func reload() { items = loadSavedItems() }
}

/// Borderless panel that can still become key (for arrow-key navigation).
final class GalleryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class GalleryController: NSObject, NSWindowDelegate {
    private var panel: GalleryPanel?
    private var monitor: Any?
    private var model: GalleryModel?
    private let onOpen: (String) -> Void

    init(onOpen: @escaping (String) -> Void) {
        self.onOpen = onOpen
    }

    func show() {
        if let p = panel, p.isVisible { close(); return }
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

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Gallery = compact below the notch; preview = large & centered (Quick Look-style).
    private func layout(preview: Bool) {
        guard let panel else { return }
        let vf = currentScreen().visibleFrame
        if preview {
            let w = vf.width * 0.82
            let h = vf.height * 0.86
            panel.setFrame(
                NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h),
                display: true, animate: false
            )
        } else {
            let w: CGFloat = 880, h: CGFloat = 400
            panel.setFrame(
                NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 6, width: w, height: h),
                display: true, animate: false
            )
        }
    }

    func close() {
        removeMonitor()
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            let count = model.items.count
            switch event.keyCode {
            case 49 where count > 0: // space -> toggle Quick Look preview
                model.previewing.toggle()
                self.layout(preview: model.previewing)
                return nil
            case 53: // esc
                if model.previewing {
                    model.previewing = false
                    self.layout(preview: false)
                } else {
                    self.close()
                }
                return nil
            case 123 where count > 0: // left
                model.selection = max(0, model.selection - 1); return nil
            case 124 where count > 0: // right
                model.selection = min(count - 1, model.selection + 1); return nil
            case 125 where count > 0: // down
                model.selection = min(count - 1, model.selection + galleryColumns); return nil
            case 126 where count > 0: // up
                model.selection = max(0, model.selection - galleryColumns); return nil
            case 36, 76: // return / enter
                guard count > 0 else { return nil }
                let path = model.items[model.selection].excalidrawPath
                self.close(); self.onOpen(path); return nil
            case 35: // 'p' -> pin/unpin selected
                guard count > 0 else { return nil }
                SettingsStore.togglePin(model.items[model.selection].excalidrawPath)
                model.reload()
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    let onOpen: (String) -> Void
    let onTogglePin: (String) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: galleryColumns)
    }
    private var pinnedCount: Int { model.items.filter { $0.pinned }.count }
    private var current: SavedItem? {
        guard model.selection >= 0, model.selection < model.items.count else { return nil }
        return model.items[model.selection]
    }

    var body: some View {
        ZStack {
            if model.previewing { previewView } else { galleryView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var galleryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved whiteboards").font(.headline)
                Spacer()
                Text("space peek · ↩ open · p pin · esc close")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.items.isEmpty {
                Text("No saved whiteboards yet. Draw something — it autosaves.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if pinnedCount > 0 {
                                sectionHeader("Pinned")
                                grid(range: 0..<pinnedCount)
                                sectionHeader("Recent")
                            }
                            grid(range: pinnedCount..<model.items.count)
                        }
                        .padding(2)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: model.selection) { _, s in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(s, anchor: .center) }
                    }
                }
            }
        }
        .padding(18)
    }

    private var previewView: some View {
        VStack(spacing: 12) {
            if let item = current, let p = item.previewPath,
               let img = downsampledImage(path: p, maxPixel: 1800) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(radius: 8)
            } else {
                Image(systemName: "doc.text.image")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(current?.name ?? "").font(.headline)
            Text("space to close · ↩ open · ←→ browse")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    @ViewBuilder
    private func grid(range: Range<Int>) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(range, id: \.self) { idx in
                let item = model.items[idx]
                cell(item, selected: idx == model.selection)
                    .id(idx)
                    .onTapGesture { onOpen(item.excalidrawPath) }
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: SavedItem, selected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
                    if let p = item.previewPath, let img = downsampledImage(path: p, maxPixel: 320) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .cornerRadius(8).padding(4)
                    } else {
                        Image(systemName: "doc.text.image").font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 100)

                Button {
                    onTogglePin(item.excalidrawPath)
                } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .foregroundStyle(item.pinned ? Color.accentColor : Color.secondary)
            }
            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}
