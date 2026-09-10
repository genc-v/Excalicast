import AppKit

/// An NSTextView that reports Escape so the canvas can commit the edit.
final class CanvasTextView: NSTextView {
    var onCommit: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCommit?() }
}

extension CanvasView {
    /// Start editing text at a world point — either a new free text element or an existing one.
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
            n.fontSize = currentFontSize
            scene.elements.append(n)
            selection = [n.id]
            element = n
        }
        presentEditor(for: element)
    }

    /// Double-click on a shape/line/arrow: edit its bound label, or create one if it has none.
    func editOrCreateBoundText(container: Element) {
        if let existing = scene.elements.first(where: { $0.kind == .text && $0.containerId == container.id }) {
            presentEditor(for: existing)
            return
        }
        history.commit(scene.elements)
        var t = Element(kind: .text)
        t.containerId = container.id
        t.strokeColor = container.isLinear ? strokeColor : strokeColor
        t.fontSize = currentFontSize
        if container.isLinear {
            let a = CGPoint(x: container.x + (container.points.first?.x ?? 0),
                            y: container.y + (container.points.first?.y ?? 0))
            let b = CGPoint(x: container.x + (container.points.last?.x ?? 0),
                            y: container.y + (container.points.last?.y ?? 0))
            t.x = (a.x + b.x) / 2; t.y = (a.y + b.y) / 2
        } else {
            t.x = container.center.x; t.y = container.center.y
        }
        scene.elements.append(t)
        if let ci = scene.index(of: container.id), !scene.elements[ci].boundElements.contains(t.id) {
            scene.elements[ci].boundElements.append(t.id)
        }
        presentEditor(for: t)
    }

    private func presentEditor(for element: Element) {
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

    /// Commit the in-progress text edit: write the string back, remeasure, re-layout if bound, then
    /// remove the overlay and return to the select tool. An empty text element is discarded.
    func commitTextEditing() {
        guard let tv = editingTextView, let id = editingElementId else { return }
        let text = tv.string
        tv.removeFromSuperview()
        editingTextView = nil
        editingElementId = nil

        if let i = scene.index(of: id) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let containerId = scene.elements[i].containerId
                scene.elements.remove(at: i)
                selection.remove(id)
                if let cid = containerId, let ci = scene.index(of: cid) {
                    scene.elements[ci].boundElements.removeAll { $0 == id }
                }
            } else {
                scene.elements[i].text = text
                let size = CanvasRenderer.measureText(scene.elements[i])
                scene.elements[i].width = size.width
                scene.elements[i].height = size.height
            }
        }
        layoutBoundText()
        tool = .select
        window?.makeFirstResponder(self)
        onChange?()
        needsDisplay = true
    }
}
