import AppKit

/// An NSTextView that reports Escape (commit) and text changes (so the canvas can keep a bound
/// label centered live as you type).
final class CanvasTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onTextChange: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCommit?() }
    override func didChangeText() { super.didChangeText(); onTextChange?() }
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
            n.textAlign = currentTextAlign
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
        t.strokeColor = strokeColor
        t.fontSize = currentFontSize
        t.textAlign = "center" // labels bound to a shape/line are centered
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
        let fontPx = element.fontSize * scene.zoom
        let tv = CanvasTextView(frame: .zero)
        tv.string = element.text
        tv.font = NSFont(name: "Helvetica Neue", size: fontPx) ?? .systemFont(ofSize: fontPx)
        tv.textColor = NSColor.fromHex(element.strokeColor) ?? .labelColor
        tv.alignment = element.textAlign == "center" ? .center : (element.textAlign == "right" ? .right : .left)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.onCommit = { [weak self] in self?.commitTextEditing() }

        // A bound label stays centered on its container (shape center / line midpoint) while typing;
        // free text grows from the click point.
        var anchorScreen: CGPoint?
        if let cid = element.containerId, let c = scene.element(id: cid) {
            let aw = c.isLinear
                ? HitTest.midpointAlong(c.points.map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) })
                : c.center
            anchorScreen = scene.toScreen(aw)
        }
        tv.onTextChange = { [weak self, weak tv] in
            guard let self, let tv else { return }
            self.layoutEditor(tv, element: element, anchorScreen: anchorScreen)
        }

        addSubview(tv)
        window?.makeFirstResponder(tv)
        editingTextView = tv
        layoutEditor(tv, element: element, anchorScreen: anchorScreen)
        needsDisplay = true
    }

    /// Size the editor to its text and keep it centered on `anchorScreen` (bound labels) or anchored
    /// at the element origin (free text).
    private func layoutEditor(_ tv: CanvasTextView, element: Element, anchorScreen: CGPoint?) {
        var probe = element
        probe.text = tv.string.isEmpty ? " " : tv.string
        let sz = CanvasRenderer.measureText(probe)
        let w = max(40, sz.width * scene.zoom) + 12
        let h = max(element.fontSize * scene.zoom * 1.3, sz.height * scene.zoom) + 4
        if let a = anchorScreen {
            tv.frame = CGRect(x: a.x - w / 2, y: a.y - h / 2, width: w, height: h)
        } else {
            let o = scene.toScreen(CGPoint(x: element.x, y: element.y))
            tv.frame = CGRect(x: o.x, y: o.y, width: w, height: h)
        }
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
