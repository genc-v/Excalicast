import AppKit
import CoreGraphics

/// The tools a user can pick. `select` manipulates existing elements, `hand` pans, the rest create.
enum Tool: String {
    case select, hand, rectangle, ellipse, diamond, line, arrow, text, pen
}

/// The eight resize handles around a shape's bounding box.
enum ResizeHandle { case nw, n, ne, e, se, s, sw, w }

/// The native drawing surface. Owns the scene + camera, handles all pointer/keyboard/trackpad input,
/// and renders via `CanvasRenderer`. Replaces the WKWebView inside the overlay panel.
final class CanvasView: NSView {
    var scene = Scene()
    let history = History()
    var tool: Tool = .select { didSet { updateCursor(); onToolChange?(tool); onStyleContextChange?() } }
    var onToolChange: ((Tool) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)? // reports zoom (1 = 100%) for the on-screen indicator
    var onStyleContextChange: (() -> Void)? // selection/tool changed → refresh the properties panel

    // Current style applied to newly-created elements.
    var strokeColor = "#1e1e1e"
    var fillColor = "transparent"
    var strokeWidth: CGFloat = 2
    var currentFontSize: CGFloat = 20

    var selection: Set<String> = [] { didSet { onStyleContextChange?() } }
    var images: [String: CGImage] = [:] // fileId -> decoded bitmap (locked screenshot background)
    var imageDataURLs: [String: String] = [:] // fileId -> original PNG dataURL, cached to avoid
                                               // re-encoding the full-res screenshot on every save

    // Text editing overlay state (see TextEditing.swift).
    var editingTextView: CanvasTextView?
    var editingElementId: String?

    var onChange: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var spaceHeld = false
    private var clipboard: [Element] = []
    private var multiPointId: String? // a line/arrow being built by clicking points one at a time
    private var highlightBindId: String? // item an arrow endpoint is about to bind to (hover outline)

    private let handlePx: CGFloat = 5 // half-size of a resize/point handle, in screen points

    private enum Drag {
        case none
        case creating(id: String)
        case moving(lastWorld: CGPoint)
        case marquee(start: CGPoint, current: CGPoint)
        case panning(lastScreen: CGPoint)
        case resizing(id: String, handle: ResizeHandle, orig: CGRect)
        case draggingPoint(id: String, index: Int)
        // A midpoint grab that only becomes a bend once the user actually drags — a plain click
        // never adds a point.
        case pendingBend(id: String, segment: Int)
    }
    private var drag: Drag = .none

    // MARK: - Setup

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var render = scene
        if let id = editingElementId { render.elements.removeAll { $0.id == id } }
        CanvasRenderer.draw(render, in: ctx, images: images,
                            backingScale: window?.backingScaleFactor ?? 2)
        if let id = highlightBindId, let el = scene.element(id: id) {
            let r = screenRect(el.bounds).insetBy(dx: -6, dy: -6)
            let path = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(2.5)
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }
        drawSelectionChrome(in: ctx)
    }

    /// Highlight the bindable item an arrow endpoint at `world` would attach to (nil clears it).
    private func updateBindHighlight(endpoint world: CGPoint, arrowId: String) {
        highlightBindId = ArrowBinding.target(at: world, in: scene, excluding: arrowId)?.id
    }

    private func drawSelectionChrome(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)

        let single = selection.count == 1 ? scene.element(id: selection.first!) : nil
        for id in selection {
            guard let el = scene.element(id: id) else { continue }
            if el.isLinear {
                // Lines/arrows: no bounding box — draw point handles (and bend midpoints if single).
                let pts = el.points.map { scene.toScreen(CGPoint(x: el.x + $0.x, y: el.y + $0.y)) }
                if selection.count == 1 {
                    for (i, p) in pts.enumerated() where i > 0 && i < pts.count - 1 {
                        drawHandle(p, in: ctx, filled: true)
                    }
                    for m in midpoints(pts) { drawHandle(m, in: ctx, filled: false) }
                }
                if let f = pts.first { drawHandle(f, in: ctx, filled: true) }
                if let l = pts.last { drawHandle(l, in: ctx, filled: true) }
            } else if el.kind == .freedraw {
                // Highlight the stroke itself (a soft accent halo) — no bounding box.
                let pts = el.points.map { scene.toScreen(CGPoint(x: el.x + $0.x, y: el.y + $0.y)) }
                if pts.count >= 2 {
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor)
                    ctx.setLineWidth(el.strokeWidth * scene.zoom + 6)
                    ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    ctx.beginPath(); ctx.move(to: pts[0])
                    for p in pts.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            } else {
                let r = screenRect(el.bounds).insetBy(dx: -1, dy: -1)
                ctx.stroke(r)
            }
        }
        // Resize handles only for a single unlocked shape (not lines, freedraw, or text).
        if let el = single, !el.usesPoints, !el.locked, el.kind != .text {
            for (_, p) in resizeHandlePoints(el) { drawHandle(p, in: ctx, filled: true) }
        }

        if case let .marquee(start, current) = drag {
            let a = scene.toScreen(start), b = scene.toScreen(current)
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor)
            ctx.fill(r)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    private func drawHandle(_ p: CGPoint, in ctx: CGContext, filled: Bool) {
        let r = CGRect(x: p.x - handlePx, y: p.y - handlePx, width: handlePx * 2, height: handlePx * 2)
        ctx.setFillColor(filled ? NSColor.controlAccentColor.cgColor : NSColor.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.strokeEllipse(in: r)
    }

    private func midpoints(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 2 else { return [] }
        return (0..<(pts.count - 1)).map {
            CGPoint(x: (pts[$0].x + pts[$0 + 1].x) / 2, y: (pts[$0].y + pts[$0 + 1].y) / 2)
        }
    }

    private func screenRect(_ world: CGRect) -> CGRect {
        let o = scene.toScreen(CGPoint(x: world.minX, y: world.minY))
        return CGRect(x: o.x, y: o.y, width: world.width * scene.zoom, height: world.height * scene.zoom)
    }

    private func worldPoint(_ event: NSEvent) -> CGPoint {
        scene.toWorld(convert(event.locationInWindow, from: nil))
    }

    // MARK: - Handle geometry

    private func resizeHandlePoints(_ el: Element) -> [(ResizeHandle, CGPoint)] {
        let r = screenRect(el.bounds)
        return [
            (.nw, CGPoint(x: r.minX, y: r.minY)), (.n, CGPoint(x: r.midX, y: r.minY)),
            (.ne, CGPoint(x: r.maxX, y: r.minY)), (.e, CGPoint(x: r.maxX, y: r.midY)),
            (.se, CGPoint(x: r.maxX, y: r.maxY)), (.s, CGPoint(x: r.midX, y: r.maxY)),
            (.sw, CGPoint(x: r.minX, y: r.maxY)), (.w, CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    private func near(_ a: CGPoint, _ b: CGPoint, radius: CGFloat) -> Bool {
        abs(a.x - b.x) <= radius && abs(a.y - b.y) <= radius
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if editingTextView != nil { commitTextEditing() }
        window?.makeFirstResponder(self)
        let w = worldPoint(event)
        let screen = convert(event.locationInWindow, from: nil)

        // Building a multi-point line/arrow by clicking: each click fixes a vertex; a double-click
        // finishes.
        if multiPointId != nil {
            if event.clickCount >= 2 { finishMultiPoint() } else { addMultiPointVertex(at: w) }
            return
        }

        if spaceHeld || tool == .hand || event.modifierFlags.contains(.option) {
            drag = .panning(lastScreen: screen); return
        }

        switch tool {
        case .select:
            if beginSelectInteraction(worldPoint: w, screenPoint: screen, event: event) { return }
        case .rectangle, .ellipse, .diamond:
            beginCreateShape(at: w)
        case .line, .arrow:
            beginCreateLinear(at: w)
        case .pen:
            beginCreateFreedraw(at: w)
        case .text:
            beginTextEditing(at: w, existing: nil)
        case .hand:
            drag = .panning(lastScreen: screen)
        }
    }

    /// Returns true if it fully handled the event (resize/bend/edit); false to fall through.
    private func beginSelectInteraction(worldPoint w: CGPoint, screenPoint screen: CGPoint,
                                        event: NSEvent) -> Bool {
        // Handles of a single selected element take priority.
        if selection.count == 1, let el = scene.element(id: selection.first!) {
            if el.isLinear {
                let pts = el.points.map { scene.toScreen(CGPoint(x: el.x + $0.x, y: el.y + $0.y)) }
                // Endpoints/real vertices win first (slightly larger target).
                for (i, p) in pts.enumerated() where near(screen, p, radius: handlePx + 3) {
                    history.commit(scene.elements)
                    // Grabbing a bound endpoint detaches it so you can drag it onto a different shape
                    // (or into empty space); it re-binds on release wherever it lands.
                    if i == 0 { ArrowBinding.detachEndpoint(&scene, arrowId: el.id, isStart: true) }
                    else if i == pts.count - 1 { ArrowBinding.detachEndpoint(&scene, arrowId: el.id, isStart: false) }
                    drag = .draggingPoint(id: el.id, index: i); return true
                }
                // Bend midpoints: tight target, and deferred until an actual drag (see pendingBend).
                let mids = midpoints(pts)
                for (i, m) in mids.enumerated() where near(screen, m, radius: handlePx) {
                    drag = .pendingBend(id: el.id, segment: i); return true
                }
            } else if !el.usesPoints, !el.locked, el.kind != .text {
                for (handle, p) in resizeHandlePoints(el) where near(screen, p, radius: handlePx + 3) {
                    history.commit(scene.elements)
                    drag = .resizing(id: el.id, handle: handle, orig: el.bounds); return true
                }
            }
        }

        // Double-click: edit text, add a bound label to a shape/line, or start free text on empty
        // canvas.
        if event.clickCount == 2 {
            let tol = 6 / scene.zoom
            if let hit = HitTest.topmost(scene.elements, w, tolerance: tol) {
                if hit.kind == .text {
                    beginTextEditing(at: CGPoint(x: hit.x, y: hit.y), existing: hit)
                } else if hit.kind == .freedraw {
                    beginTextEditing(at: w, existing: nil) // don't bind labels to pen strokes
                } else {
                    editOrCreateBoundText(container: hit)
                }
            } else {
                beginTextEditing(at: w, existing: nil)
            }
            return true
        }

        beginSelectOrMove(at: w, event: event)
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        let w = worldPoint(event)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .panning(let last):
            let now = convert(event.locationInWindow, from: nil)
            scene.scrollX += (now.x - last.x) / scene.zoom
            scene.scrollY += (now.y - last.y) / scene.zoom
            drag = .panning(lastScreen: now); needsDisplay = true
        case .creating(let id):
            updateCreating(id: id, to: w, shift: shift)
        case .moving(let last):
            moveSelection(by: CGPoint(x: w.x - last.x, y: w.y - last.y))
            drag = .moving(lastWorld: w)
        case .marquee(let start, _):
            drag = .marquee(start: start, current: w); needsDisplay = true
        case .resizing(let id, let handle, let orig):
            resizeElement(id: id, handle: handle, orig: orig, to: w, shift: shift)
        case .draggingPoint(let id, let index):
            movePoint(id: id, index: index, to: w, shift: shift)
        case .pendingBend(let id, let segment):
            // First real drag: now insert the bend point and start dragging it.
            history.commit(scene.elements)
            insertBendPoint(id: id, afterSegment: segment, at: w)
            drag = .draggingPoint(id: id, index: segment + 1)
            movePoint(id: id, index: segment + 1, to: w, shift: shift)
        case .none:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let id = multiPointId, let i = scene.index(of: id),
              let last = scene.elements[i].points.indices.last else { return }
        var end = worldPoint(event)
        if event.modifierFlags.contains(.shift), scene.elements[i].points.count >= 2 {
            let prev = scene.elements[i].points[last - 1]
            let base = CGPoint(x: scene.elements[i].x + prev.x, y: scene.elements[i].y + prev.y)
            end = snap45(from: base, to: end)
        }
        scene.elements[i].points[last] = CGPoint(x: end.x - scene.elements[i].x,
                                                 y: end.y - scene.elements[i].y)
        updateBindHighlight(endpoint: end, arrowId: id)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating(let id):
            // A click (no meaningful drag) on the line/arrow tool begins multi-point mode instead
            // of finishing a 2-point line.
            if let el = scene.element(id: id), el.isLinear,
               hypot(el.points.last?.x ?? 0, el.points.last?.y ?? 0) < 6 {
                beginMultiPoint(id: id); drag = .none; needsDisplay = true; return
            }
            finishCreating(id: id)
        case .marquee(let start, let current):
            commitMarquee(from: start, to: current, additive: event.modifierFlags.contains(.shift))
        case .moving: onChange?()
        case .resizing(let id, _, _): afterGeometryChange([id]); onChange?()
        case .draggingPoint(let id, _): rebindLinear(id: id); afterGeometryChange([id]); onChange?()
        default: break
        }
        drag = .none
        highlightBindId = nil
        needsDisplay = true
    }

    // MARK: - Select / move

    private func beginSelectOrMove(at w: CGPoint, event: NSEvent) {
        let tol = 6 / scene.zoom
        if let hit = HitTest.topmost(scene.elements, w, tolerance: tol) {
            if event.modifierFlags.contains(.shift) {
                if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
            } else if !selection.contains(hit.id) {
                selection = [hit.id]
            }
            if !selection.isEmpty { history.commit(scene.elements); drag = .moving(lastWorld: w) }
        } else {
            if !event.modifierFlags.contains(.shift) { selection.removeAll() }
            drag = .marquee(start: w, current: w)
        }
        needsDisplay = true
    }

    private func moveSelection(by delta: CGPoint) {
        for id in selection {
            guard let i = scene.index(of: id) else { continue }
            scene.elements[i].x += delta.x
            scene.elements[i].y += delta.y
        }
        afterGeometryChange(selection)
        needsDisplay = true
    }

    private func commitMarquee(from a: CGPoint, to b: CGPoint, additive: Bool) {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if !additive { selection.removeAll() }
        for el in scene.elements where !el.locked && el.containerId == nil {
            // Point-based strokes (lines/arrows/pen) select only when the marquee actually crosses
            // the stroke — not just its (often huge) bounding box.
            let hit = el.usesPoints ? HitTest.rectIntersectsLinear(r, el) : r.intersects(el.bounds)
            if hit { selection.insert(el.id) }
        }
    }

    // MARK: - Resize / bend

    private func resizeElement(id: String, handle: ResizeHandle, orig: CGRect, to w: CGPoint, shift: Bool) {
        guard let i = scene.index(of: id) else { return }
        var minX = orig.minX, minY = orig.minY, maxX = orig.maxX, maxY = orig.maxY
        switch handle {
        case .nw: minX = w.x; minY = w.y
        case .n: minY = w.y
        case .ne: maxX = w.x; minY = w.y
        case .e: maxX = w.x
        case .se: maxX = w.x; maxY = w.y
        case .s: maxY = w.y
        case .sw: minX = w.x; maxY = w.y
        case .w: minX = w.x
        }
        var rect = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))
        if shift, rect.width > 0, rect.height > 0 { // keep aspect from original
            let s = max(rect.width / max(orig.width, 1), rect.height / max(orig.height, 1))
            rect.size = CGSize(width: orig.width * s, height: orig.height * s)
        }
        scene.elements[i].x = rect.minX
        scene.elements[i].y = rect.minY
        scene.elements[i].width = max(2, rect.width)
        scene.elements[i].height = max(2, rect.height)
        afterGeometryChange([id])
        needsDisplay = true
    }

    private func insertBendPoint(id: String, afterSegment i: Int, at w: CGPoint) {
        guard let idx = scene.index(of: id) else { return }
        let rel = CGPoint(x: w.x - scene.elements[idx].x, y: w.y - scene.elements[idx].y)
        scene.elements[idx].points.insert(rel, at: i + 1)
    }

    private func movePoint(id: String, index: Int, to w: CGPoint, shift: Bool) {
        guard let i = scene.index(of: id), scene.elements[i].points.indices.contains(index) else { return }
        var target = w
        if shift, scene.elements[i].points.count >= 2 { // snap to 45° from the neighbouring point
            let neighbor = index > 0 ? index - 1 : 1
            let base = CGPoint(x: scene.elements[i].x + scene.elements[i].points[neighbor].x,
                               y: scene.elements[i].y + scene.elements[i].points[neighbor].y)
            target = snap45(from: base, to: w)
        }
        scene.elements[i].points[index] = CGPoint(x: target.x - scene.elements[i].x,
                                                  y: target.y - scene.elements[i].y)
        // Re-anchor origin so points stay tidy and bounds/width/height stay correct.
        normalizeLinear(&scene.elements[i])
        if index == 0 || index == scene.elements[i].points.count - 1 {
            updateBindHighlight(endpoint: target, arrowId: id)
        }
        afterGeometryChange([id])
        needsDisplay = true
    }

    // MARK: - Create shapes / lines

    private func beginCreateShape(at w: CGPoint) {
        history.commit(scene.elements)
        var el = Element(kind: toolKind())
        el.x = w.x; el.y = w.y
        applyStyle(&el)
        scene.elements.append(el)
        selection = [el.id]
        drag = .creating(id: el.id)
    }

    private func beginCreateLinear(at w: CGPoint) {
        history.commit(scene.elements)
        var el = Element(kind: tool == .arrow ? .arrow : .line)
        el.x = w.x; el.y = w.y
        el.points = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)]
        if tool == .arrow { el.endArrowhead = "arrow" }
        applyStyle(&el)
        scene.elements.append(el)
        selection = [el.id]
        drag = .creating(id: el.id)
    }

    private func beginCreateFreedraw(at w: CGPoint) {
        history.commit(scene.elements)
        var el = Element(kind: .freedraw)
        el.x = w.x; el.y = w.y
        el.points = [CGPoint(x: 0, y: 0)]
        applyStyle(&el)
        scene.elements.append(el)
        selection.removeAll() // don't leave a selection outline while drawing
        drag = .creating(id: el.id)
    }

    private func updateCreating(id: String, to w: CGPoint, shift: Bool) {
        guard let i = scene.index(of: id) else { return }
        if scene.elements[i].kind == .freedraw {
            // Append each sampled point (relative to the element origin) to trace the stroke.
            scene.elements[i].points.append(CGPoint(x: w.x - scene.elements[i].x,
                                                    y: w.y - scene.elements[i].y))
            needsDisplay = true
            return
        }
        if scene.elements[i].isLinear {
            var end = w
            if shift { end = snap45(from: CGPoint(x: scene.elements[i].x, y: scene.elements[i].y), to: w) }
            scene.elements[i].points[1] = CGPoint(x: end.x - scene.elements[i].x,
                                                  y: end.y - scene.elements[i].y)
            updateBindHighlight(endpoint: end, arrowId: id)
        } else {
            let e = scene.elements[i]
            var dw = w.x - e.x, dh = w.y - e.y
            if shift { let s = max(abs(dw), abs(dh)); dw = dw < 0 ? -s : s; dh = dh < 0 ? -s : s }
            scene.elements[i].width = dw
            scene.elements[i].height = dh
        }
        needsDisplay = true
    }

    private func finishCreating(id: String) {
        guard let i = scene.index(of: id) else { return }
        var el = scene.elements[i]
        if el.kind == .freedraw {
            if el.points.count < 2 { // a click makes a dot
                el.points.append(CGPoint(x: el.points[0].x + 0.5, y: el.points[0].y + 0.5))
            }
            scene.elements[i] = el
            normalizeLinear(&scene.elements[i])
            onChange?()
            return // keep the pen active for continuous drawing
        }
        if el.isLinear {
            if hypot(el.points[1].x, el.points[1].y) < 3 {
                scene.elements.remove(at: i); selection.removeAll(); return
            }
            normalizeLinear(&scene.elements[i])
            rebindLinear(id: id)
        } else {
            if el.width < 0 { el.x += el.width; el.width = -el.width }
            if el.height < 0 { el.y += el.height; el.height = -el.height }
            if el.width < 3 && el.height < 3 { scene.elements.remove(at: i); selection.removeAll(); return }
            scene.elements[i] = el
        }
        tool = .select
        onChange?()
    }

    // MARK: - Multi-point (click-to-place) line/arrow

    private func beginMultiPoint(id: String) {
        multiPointId = id
        window?.acceptsMouseMovedEvents = true
        // points is [start, floating]; the floating last point now follows the cursor via mouseMoved.
        needsDisplay = true
    }

    private func addMultiPointVertex(at w: CGPoint) {
        guard let mp = multiPointId, let i = scene.index(of: mp) else { return }
        let rel = CGPoint(x: w.x - scene.elements[i].x, y: w.y - scene.elements[i].y)
        // Fix the floating point here, then append a new floating point to keep going.
        if let last = scene.elements[i].points.indices.last {
            scene.elements[i].points[last] = rel
        }
        scene.elements[i].points.append(rel)
        needsDisplay = true
    }

    func finishMultiPoint() {
        defer { multiPointId = nil; window?.acceptsMouseMovedEvents = false; highlightBindId = nil }
        guard let mp = multiPointId, let i = scene.index(of: mp) else { return }
        // Drop the trailing floating point.
        if scene.elements[i].points.count > 2 { scene.elements[i].points.removeLast() }
        // Degenerate (single real segment with no length) → discard.
        if scene.elements[i].points.count < 2 ||
            (scene.elements[i].bounds.width < 3 && scene.elements[i].bounds.height < 3) {
            scene.elements.remove(at: i); selection.removeAll()
        } else {
            normalizeLinear(&scene.elements[i])
            rebindLinear(id: mp)
        }
        tool = .select
        onChange?()
        needsDisplay = true
    }

    private func toolKind() -> ElementKind {
        switch tool {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .diamond: return .diamond
        default: return .rectangle
        }
    }

    private func applyStyle(_ el: inout Element) {
        el.strokeColor = strokeColor
        el.backgroundColor = fillColor
        el.strokeWidth = strokeWidth
    }

    // MARK: - Style editing (properties panel)

    /// Apply a mutation to all selected elements (committing undo) — or, if nothing is selected, the
    /// caller has already updated the tool defaults.
    private func applyToSelection(_ change: (inout Element) -> Void) {
        guard !selection.isEmpty else { needsDisplay = true; return }
        history.commit(scene.elements)
        for id in selection { if let i = scene.index(of: id) { change(&scene.elements[i]) } }
        onChange?(); needsDisplay = true
    }

    func setStrokeColor(_ hex: String) { strokeColor = hex; applyToSelection { $0.strokeColor = hex }; onStyleContextChange?() }
    func setFillColor(_ hex: String) { fillColor = hex; applyToSelection { $0.backgroundColor = hex }; onStyleContextChange?() }
    func setStrokeWidth(_ w: CGFloat) { strokeWidth = w; applyToSelection { $0.strokeWidth = w }; onStyleContextChange?() }

    func setFontSize(_ s: CGFloat) {
        currentFontSize = s
        if !selection.isEmpty {
            history.commit(scene.elements)
            for id in selection where scene.element(id: id)?.kind == .text {
                guard let i = scene.index(of: id) else { continue }
                scene.elements[i].fontSize = s
                let sz = CanvasRenderer.measureText(scene.elements[i])
                scene.elements[i].width = sz.width; scene.elements[i].height = sz.height
            }
            layoutBoundText(); onChange?()
        }
        needsDisplay = true; onStyleContextChange?()
    }

    // Effective values to display: the selection's (first element), else the tool defaults.
    private var firstSelectedElement: Element? {
        for id in selection { if let e = scene.element(id: id) { return e } }
        return nil
    }
    private var selectedKinds: Set<ElementKind> { Set(selection.compactMap { scene.element(id: $0)?.kind }) }

    var uiStrokeColor: String { firstSelectedElement?.strokeColor ?? strokeColor }
    var uiFillColor: String { firstSelectedElement?.backgroundColor ?? fillColor }
    var uiStrokeWidth: CGFloat { firstSelectedElement?.strokeWidth ?? strokeWidth }
    var uiFontSize: CGFloat {
        for id in selection where scene.element(id: id)?.kind == .text { return scene.element(id: id)!.fontSize }
        return currentFontSize
    }

    /// Whether the properties panel should be visible, and which sections apply.
    var propsVisible: Bool {
        if !selection.isEmpty { return true }
        return [.rectangle, .ellipse, .diamond, .line, .arrow, .pen, .text].contains(tool)
    }
    var showsFill: Bool {
        let shapes: Set<ElementKind> = [.rectangle, .ellipse, .diamond]
        if !selection.isEmpty { return !selectedKinds.isDisjoint(with: shapes) }
        return [.rectangle, .ellipse, .diamond].contains(tool)
    }
    var showsFont: Bool {
        if !selection.isEmpty { return selectedKinds.contains(.text) }
        return tool == .text
    }
    /// Stroke width applies to everything except text (and images).
    var showsWidth: Bool {
        if !selection.isEmpty { return selectedKinds.contains { $0 != .text && $0 != .image } }
        return tool != .text
    }

    // MARK: - Geometry helpers

    /// Snap the vector base→p to the nearest 45° increment.
    private func snap45(from base: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - base.x, dy = p.y - base.y
        let len = hypot(dx, dy)
        guard len > 0 else { return p }
        let angle = atan2(dy, dx)
        let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: base.x + cos(snapped) * len, y: base.y + sin(snapped) * len)
    }

    /// Re-anchor a linear element's origin at its first point so points stay relative and bounds fit.
    private func normalizeLinear(_ el: inout Element) {
        guard let first = el.points.first else { return }
        if first != .zero {
            el.x += first.x; el.y += first.y
            el.points = el.points.map { CGPoint(x: $0.x - first.x, y: $0.y - first.y) }
        }
        let b = el.bounds
        el.width = b.width; el.height = b.height
    }

    // MARK: - Binding / bound text

    private func afterGeometryChange(_ ids: Set<String>) {
        ArrowBinding.reflow(&scene, movedIds: ids)
        layoutBoundText()
    }

    func reflowBoundArrows(movedIds: Set<String>) { ArrowBinding.reflow(&scene, movedIds: movedIds) }
    private func rebindLinear(id: String) {
        if let i = scene.index(of: id) { ArrowBinding.bindEndpoints(&scene, arrowIndex: i) }
    }

    /// Re-center every bound text inside its container (shape center) or a line's midpoint.
    func layoutBoundText() {
        for i in scene.elements.indices where scene.elements[i].kind == .text {
            guard let cid = scene.elements[i].containerId, let c = scene.element(id: cid) else { continue }
            let size = CanvasRenderer.measureText(scene.elements[i])
            let anchor: CGPoint
            if c.isLinear {
                anchor = HitTest.midpointAlong(c.points.map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) })
            } else {
                anchor = c.center
            }
            scene.elements[i].x = anchor.x - size.width / 2
            scene.elements[i].y = anchor.y - size.height / 2
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

        // Finishing a multi-point line takes priority over other keys.
        if multiPointId != nil, event.keyCode == 53 || event.keyCode == 36 { // Esc / Return
            finishMultiPoint(); return
        }

        switch event.keyCode {
        case 53: // Esc
            if !selection.isEmpty || tool != .select { selection.removeAll(); tool = .select; needsDisplay = true }
            else { onDismiss?() }
            return
        case 49: // Space -> temporary pan
            if !spaceHeld { spaceHeld = true; NSCursor.openHand.set() }
            return
        case 51, 117: // Delete
            if !selection.isEmpty { deleteSelection() }
            return
        case 123, 124, 125, 126: // arrows -> nudge
            if !selection.isEmpty { nudge(keyCode: event.keyCode, big: shift); return }
        default: break
        }

        if cmd {
            switch chars {
            case "z": shift ? redo() : undo(); return
            case "a": selection = Set(scene.elements.filter { !$0.locked && $0.containerId == nil }.map { $0.id }); needsDisplay = true; return
            case "c": clipboard = scene.elements.filter { selection.contains($0.id) }; return
            case "v": pasteElements(); return
            case "x": clipboard = scene.elements.filter { selection.contains($0.id) }; deleteSelection(); return
            case "d": duplicateSelection(); return
            case "=", "+": zoomStep(1.1); return
            case "-", "_": zoomStep(1 / 1.1); return
            case "0": resetZoom(); return
            default: return
            }
        }
        if shift, chars == "1" { zoomToFit(); return } // Shift+1 = zoom to fit

        switch chars {
        case "v", "1": tool = .select
        case "h": tool = .hand
        case "r", "2": tool = .rectangle
        case "d", "3": tool = .diamond
        case "o", "4": tool = .ellipse
        case "a", "5": tool = .arrow
        case "l", "6": tool = .line
        case "p", "7": tool = .pen
        case "t", "8": tool = .text
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; updateCursor() }
    }

    private func nudge(keyCode: UInt16, big: Bool) {
        let step: CGFloat = big ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch keyCode { case 123: dx = -step; case 124: dx = step; case 125: dy = step; case 126: dy = -step; default: break }
        history.commit(scene.elements)
        for id in selection {
            guard let i = scene.index(of: id) else { continue }
            scene.elements[i].x += dx; scene.elements[i].y += dy
        }
        afterGeometryChange(selection); onChange?(); needsDisplay = true
    }

    private func deleteSelection() {
        history.commit(scene.elements)
        // Deleting a container also removes its bound text.
        var toRemove = selection
        for el in scene.elements where el.containerId != nil && selection.contains(el.containerId!) {
            toRemove.insert(el.id)
        }
        scene.elements.removeAll { toRemove.contains($0.id) }
        ArrowBinding.purge(&scene, deleted: toRemove)
        selection.removeAll()
        onChange?(); needsDisplay = true
    }

    private func undo() {
        if let prev = history.undo(current: scene.elements) {
            scene.elements = prev; selection.removeAll(); onChange?(); needsDisplay = true
        }
    }
    private func redo() {
        if let next = history.redo(current: scene.elements) {
            scene.elements = next; selection.removeAll(); onChange?(); needsDisplay = true
        }
    }

    // MARK: - Copy / paste / duplicate

    private func cloneElements(_ els: [Element], offset: CGFloat) -> [Element] {
        var idMap: [String: String] = [:]
        var copies = els.map { e -> Element in
            var c = e; let nid = Element.newId(); idMap[e.id] = nid
            c.id = nid; c.x += offset; c.y += offset; return c
        }
        for i in copies.indices {
            if let b = copies[i].startBinding { copies[i].startBinding = idMap[b.elementId].map { Binding(elementId: $0, focus: b.focus, gap: b.gap) } }
            if let b = copies[i].endBinding { copies[i].endBinding = idMap[b.elementId].map { Binding(elementId: $0, focus: b.focus, gap: b.gap) } }
            copies[i].boundElements = copies[i].boundElements.compactMap { idMap[$0] }
            if let cid = copies[i].containerId { copies[i].containerId = idMap[cid] }
        }
        return copies
    }

    private func pasteElements() {
        guard !clipboard.isEmpty else { return }
        history.commit(scene.elements)
        let copies = cloneElements(clipboard, offset: 20)
        scene.elements.append(contentsOf: copies)
        selection = Set(copies.filter { $0.containerId == nil }.map { $0.id })
        onChange?(); needsDisplay = true
    }

    private func duplicateSelection() {
        guard !selection.isEmpty else { return }
        history.commit(scene.elements)
        let sel = scene.elements.filter { selection.contains($0.id) }
        let copies = cloneElements(sel, offset: 20)
        scene.elements.append(contentsOf: copies)
        selection = Set(copies.filter { $0.containerId == nil }.map { $0.id })
        onChange?(); needsDisplay = true
    }

    // MARK: - Pan / zoom

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            zoom(by: 1 + event.scrollingDeltaY * 0.01, at: p)
            return
        }
        scene.scrollX += event.scrollingDeltaX / scene.zoom
        scene.scrollY += event.scrollingDeltaY / scene.zoom
        needsDisplay = true
    }

    private func zoomStep(_ f: CGFloat) { zoom(by: f, at: CGPoint(x: bounds.midX, y: bounds.midY)) }

    func zoomIn() { zoomStep(1.1) }
    func zoomOut() { zoomStep(1 / 1.1) }
    func resetZoom() { zoom(by: 1 / scene.zoom, at: CGPoint(x: bounds.midX, y: bounds.midY)) }

    func zoom(by factor: CGFloat, at screenPoint: CGPoint) {
        let before = scene.toWorld(screenPoint)
        scene.zoom = max(0.1, min(30, scene.zoom * factor))
        let after = scene.toWorld(screenPoint)
        scene.scrollX += after.x - before.x
        scene.scrollY += after.y - before.y
        onZoomChange?(scene.zoom)
        needsDisplay = true
    }

    // MARK: - Camera

    /// Restore a saved camera (used when reopening the document you were last working on).
    func setCamera(scrollX: CGFloat, scrollY: CGFloat, zoom: CGFloat) {
        scene.scrollX = scrollX; scene.scrollY = scrollY; scene.zoom = max(0.1, min(30, zoom))
        onZoomChange?(scene.zoom); needsDisplay = true
    }

    /// Reset the camera to 1:1 with no offset (used by frozen mode so the screenshot fills exactly).
    func resetCamera() {
        scene.zoom = 1; scene.scrollX = 0; scene.scrollY = 0
        onZoomChange?(scene.zoom); needsDisplay = true
    }

    /// Reset to 100% zoom and center the content (or the locked screenshot) in the view.
    func recenter() {
        scene.zoom = 1
        let target = scene.elements.first(where: { $0.locked })?.bounds ?? scene.contentBounds()
        if let b = target {
            scene.scrollX = (bounds.width - b.width) / 2 - b.minX
            scene.scrollY = (bounds.height - b.height) / 2 - b.minY
        } else {
            scene.scrollX = 0; scene.scrollY = 0
        }
        onZoomChange?(scene.zoom); needsDisplay = true
    }

    /// Zoom so all content fits the viewport (Excalidraw's Shift+1). May zoom in or out.
    func zoomToFit() {
        let target = scene.elements.first(where: { $0.locked })?.bounds ?? scene.contentBounds()
        guard let b = target, b.width > 0, b.height > 0 else { resetCamera(); return }
        let margin: CGFloat = 40
        let sx = (bounds.width - margin * 2) / b.width
        let sy = (bounds.height - margin * 2) / b.height
        scene.zoom = max(0.1, min(4, min(sx, sy)))
        scene.scrollX = (bounds.width / scene.zoom - b.width) / 2 - b.minX
        scene.scrollY = (bounds.height / scene.zoom - b.height) / 2 - b.minY
        onZoomChange?(scene.zoom); needsDisplay = true
    }

    private func updateCursor() {
        switch tool {
        case .select: NSCursor.arrow.set()
        case .hand: NSCursor.openHand.set()
        default: NSCursor.crosshair.set()
        }
    }
}
