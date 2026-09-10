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
        if let ci = scene.index(of: container.id) {
            if !scene.elements[ci].boundElements.contains(t.id) { scene.elements[ci].boundElements.append(t.id) }
            // Pin the current height as the floor so adding a label never shrinks the shape.
            if scene.elements[ci].minHeight == 0 { scene.elements[ci].minHeight = scene.elements[ci].height }
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

        // Text inside a shape wraps to the shape's width; configure the field editor to word-wrap.
        if let cid = element.containerId, let c = scene.element(id: cid), !c.isLinear {
            tv.isHorizontallyResizable = false
            tv.textContainer?.widthTracksTextView = true
        }
        tv.onTextChange = { [weak self, weak tv] in
            guard let self, let tv else { return }
            self.layoutEditor(tv, element: element)
        }

        addSubview(tv)
        window?.makeFirstResponder(tv)
        editingTextView = tv
        layoutEditor(tv, element: element)
        needsDisplay = true
    }

    /// Position/size the editor. Shape labels wrap to the shape's inner width and grow the shape's
    /// height live; line labels center on the midpoint; free text grows from the click point.
    private func layoutEditor(_ tv: CanvasTextView, element: Element) {
        let pad = CanvasView.labelPadding
        var probe = element
        probe.text = tv.string.isEmpty ? " " : tv.string

        if let cid = element.containerId, let ci = scene.index(of: cid), !scene.elements[ci].isLinear {
            let innerW = max(24, scene.elements[ci].width - pad * 2)
            let sz = CanvasRenderer.measureText(probe, maxWidth: innerW)
            // Grow to fit; never below the shape's drawn/resized height (no shrink on typing).
            scene.elements[ci].height = max(sz.height + pad * 2, scene.elements[ci].minHeight, 24)
            ArrowBinding.reflow(&scene, movedIds: [cid])
            let c = scene.elements[ci]
            let o = scene.toScreen(CGPoint(x: c.x + pad, y: c.y + (c.height - sz.height) / 2))
            tv.frame = CGRect(x: o.x, y: o.y, width: innerW * scene.zoom, height: sz.height * scene.zoom + 2)
            needsDisplay = true
            return
        }

        let sz = CanvasRenderer.measureText(probe)
        let w = max(40, sz.width * scene.zoom) + 12
        let h = max(element.fontSize * scene.zoom * 1.3, sz.height * scene.zoom) + 4
        if let cid = element.containerId, let c = scene.element(id: cid), c.isLinear {
            let mid = HitTest.midpointAlong(c.points.map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) })
            let a = scene.toScreen(mid)
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
