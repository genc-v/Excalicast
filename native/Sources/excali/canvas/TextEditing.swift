import AppKit

/// An NSTextView that reports Escape so the canvas can commit the edit.
final class CanvasTextView: NSTextView {
    var onCommit: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCommit?() }
}

extension CanvasView {
    /// Start editing text at a world point — either a new text element or an existing one.
    func beginTextEditing(at world: CGPoint, existing: Element?) {
        commitTextEditing()

        let element: Element
        if let e = existing {
            element = e
        } else {
            history.commit(scene.elements)
            var n = Element(kind: .text)
            n.x = world.x; n.y = world.y
            n.strokeColor = strokeColor
            n.fontSize = 20
            scene.elements.append(n)
            selection = [n.id]
            element = n
        }
        editingElementId = element.id

        let origin = scene.toScreen(CGPoint(x: element.x, y: element.y))
        let fontPx = element.fontSize * scene.zoom
        let tv = CanvasTextView(frame: CGRect(
            x: origin.x, y: origin.y,
            width: max(160, element.width * scene.zoom + 20),
            height: max(fontPx * 1.4, element.height * scene.zoom)))
        tv.string = element.text
        tv.font = NSFont(name: "Helvetica Neue", size: fontPx) ?? .systemFont(ofSize: fontPx)
        tv.textColor = NSColor.fromHex(element.strokeColor) ?? .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.onCommit = { [weak self] in self?.commitTextEditing() }

        addSubview(tv)
        window?.makeFirstResponder(tv)
        editingTextView = tv
        needsDisplay = true
    }

    /// Commit the in-progress text edit: write the string back, remeasure, and remove the overlay.
    /// An empty text element is discarded.
    func commitTextEditing() {
        guard let tv = editingTextView, let id = editingElementId else { return }
        let text = tv.string
        tv.removeFromSuperview()
        editingTextView = nil
        editingElementId = nil

        if let i = scene.index(of: id) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scene.elements.remove(at: i)
                selection.remove(id)
            } else {
                scene.elements[i].text = text
                let size = CanvasRenderer.measureText(scene.elements[i])
                scene.elements[i].width = size.width
                scene.elements[i].height = size.height
            }
        }
        onChange?()
        needsDisplay = true
    }
}
