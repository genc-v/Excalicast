import Foundation

/// A saved `.excalidraw` document with its sibling `.png` preview.
struct SavedItem: Identifiable {
    let id = UUID()
    let excalidrawPath: String
    let previewPath: String?
    let name: String
    let date: Date
    let pinned: Bool
}

/// Reads / prunes the saved documents in the configured folder. Pure file-system concern.
enum SavedDocuments {
    /// All saved items — pinned first, then newest first.
    static func all() -> [SavedItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: SettingsStore.resolvedSaveDir()),
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let items = urls
            .filter { $0.pathExtension == "excalidraw" }
            .map { url -> SavedItem in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
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

    /// The most recently modified document (the last one worked on).
    static func newestPath() -> String? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: SettingsStore.resolvedSaveDir()),
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

    /// Move oldest non-pinned items beyond the retention limit to the Trash (0 = unlimited).
    static func prune() {
        let limit = SettingsStore.maxItems
        guard limit > 0 else { return }
        let nonPinned = all().filter { !$0.pinned } // newest-first
        guard nonPinned.count > limit else { return }
        let fm = FileManager.default
        for item in nonPinned.suffix(nonPinned.count - limit) {
            try? fm.trashItem(at: URL(fileURLWithPath: item.excalidrawPath), resultingItemURL: nil)
            if let p = item.previewPath {
                try? fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
        }
    }

    /// Number of non-pinned saved documents (used for retention warnings).
    static func nonPinnedCount() -> Int {
        all().filter { !$0.pinned }.count
    }
}
