import SwiftUI

/// The Spotlight-style gallery UI: a glass grid with Pinned/Recent sections and a Quick Look
/// preview. Pure view — all behavior lives in `GalleryController`.
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
               let img = ThumbnailCache.image(path: p, maxPixel: 1800) {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(radius: 8)
            } else {
                Image(systemName: "doc.text.image")
                    .font(.system(size: 64)).foregroundStyle(.secondary)
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
                    if let p = item.previewPath, let img = ThumbnailCache.image(path: p, maxPixel: 320) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .cornerRadius(8).padding(4)
                    } else {
                        Image(systemName: "doc.text.image").font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 100)

                Button { onTogglePin(item.excalidrawPath) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11)).padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain).padding(4)
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
