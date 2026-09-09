import AppKit
import CoreGraphics

/// The tools a user can pick. `select` manipulates existing elements; the rest create new ones.
enum Tool: String {
    case select, rectangle, ellipse, diamond, line, arrow, text
}

/// The native drawing surface. Owns the scene + camera, handles all pointer/keyboard/trackpad input,
/// and renders via `CanvasRenderer`. Replaces the WKWebView inside the overlay panel.
final class CanvasView: NSView {
    var scene = Scene()
    let history = History()
    var tool: Tool = .select { didSet { updateCursor(); onToolChange?(tool) } }
    var onToolChange: ((Tool) -> Void)?

    // Current style applied to newly-created elements.
    var strokeColor = "#1e1e1e"
    var fillColor = "transparent"
    var strokeWidth: CGFloat = 2

    var selection: Set<String> = []
    var images: [String: CGImage] = [:] // fileId -> decoded bitmap (locked screenshot background)

    // Text editing overlay state (see TextEditing.swift).
    var editingTextView: CanvasTextView?
    var editingElementId: String?

    /// Called after any change that should trigger autosave.
    var onChange: (() -> Void)?
    /// Called when the user requests dismiss (Esc with nothing to cancel).
    var onDismiss: (() -> Void)?

    // MARK: - Drag state

    private enum Drag {
        case none
        case creating(id: String)
        case moving(lastWorld: CGPoint)
        case marquee(start: CGPoint, current: CGPoint)
        case panning(lastScreen: CGPoint)
    }
    private var drag: Drag = .none

    // MARK: - Setup

    override var isFlipped: Bool { true } // y grows downward, matching screen + Excalidraw coords
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var render = scene
        // The element being edited is shown by the live NSTextView overlay instead.
        if let id = editingElementId { render.elements.removeAll { $0.id == id } }
        CanvasRenderer.draw(render, in: ctx, images: images,
                            backingScale: window?.backingScaleFactor ?? 2)
        drawSelectionChrome(in: ctx)
    }

    private func drawSelectionChrome(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1)
        for id in selection {
            guard let el = scene.element(id: id) else { continue }
            let r = screenRect(el.bounds).insetBy(dx: -3, dy: -3)
            ctx.stroke(r)
        }
        if case let .marquee(start, current) = drag {
            let a = scene.toScreen(start), b = scene.toScreen(current)
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.1).cgColor)
            ctx.fill(r)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    private func screenRect(_ world: CGRect) -> CGRect {
        let o = scene.toScreen(CGPoint(x: world.minX, y: world.minY))
        return CGRect(x: o.x, y: o.y, width: world.width * scene.zoom, height: world.height * scene.zoom)
    }

    private func worldPoint(_ event: NSEvent) -> CGPoint {
        scene.toWorld(convert(event.locationInWindow, from: nil))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if editingTextView != nil { commitTextEditing() } // clicking the canvas commits any edit
        window?.makeFirstResponder(self)
        let w = worldPoint(event)
        // Option held → pan regardless of tool.
        if event.modifierFlags.contains(.option) {
            drag = .panning(lastScreen: convert(event.locationInWindow, from: nil))
            return
        }
        switch tool {
        case .select:
            // Double-click a text element to edit it.
            if event.clickCount == 2, let hit = HitTest.topmost(scene.elements, w, tolerance: 6 / scene.zoom),
               hit.kind == .text {
                beginTextEditing(at: CGPoint(x: hit.x, y: hit.y), existing: hit)
                return
            }
            beginSelectOrMove(at: w, event: event)
        case .rectangle, .ellipse, .diamond:
            beginCreateShape(at: w)
        case .line, .arrow:
            beginCreateLinear(at: w)
        case .text:
            beginTextEditing(at: w, existing: nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let w = worldPoint(event)
        switch drag {
        case .panning(let last):
            let now = convert(event.locationInWindow, from: nil)
            scene.scrollX += (now.x - last.x) / scene.zoom
            scene.scrollY += (now.y - last.y) / scene.zoom
            drag = .panning(lastScreen: now)
            needsDisplay = true
        case .creating(let id):
            updateCreating(id: id, to: w)
        case .moving(let last):
            moveSelection(by: CGPoint(x: w.x - last.x, y: w.y - last.y))
            drag = .moving(lastWorld: w)
        case .marquee(let start, _):
            drag = .marquee(start: start, current: w)
            needsDisplay = true
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating(let id):
            finishCreating(id: id)
        case .marquee(let start, let current):
            commitMarquee(from: start, to: current, additive: event.modifierFlags.contains(.shift))
        case .moving:
            onChange?()
        default:
            break
        }
        drag = .none
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
            if !selection.isEmpty {
                history.commit(scene.elements)
                drag = .moving(lastWorld: w)
            }
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
        reflowBoundArrows(movedIds: selection)
        needsDisplay = true
    }

    private func commitMarquee(from a: CGPoint, to b: CGPoint, additive: Bool) {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if !additive { selection.removeAll() }
        for el in scene.elements where !el.locked {
            if r.intersects(el.bounds) { selection.insert(el.id) }
        }
    }

    // MARK: - Create shapes / lines

    private func beginCreateShape(at w: CGPoint) {
        history.commit(scene.elements)
        var el = Element(kind: toolKind())
        el.x = w.x; el.y = w.y; el.width = 0; el.height = 0
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

    private func updateCreating(id: String, to w: CGPoint) {
        guard let i = scene.index(of: id) else { return }
        if scene.elements[i].isLinear {
            scene.elements[i].points[1] = CGPoint(x: w.x - scene.elements[i].x,
                                                  y: w.y - scene.elements[i].y)
        } else {
            let e = scene.elements[i]
            scene.elements[i].width = w.x - e.x
            scene.elements[i].height = w.y - e.y
        }
        needsDisplay = true
    }

    private func finishCreating(id: String) {
        guard let i = scene.index(of: id) else { return }
        var el = scene.elements[i]
        if el.isLinear {
            let end = el.points[1]
            if hypot(end.x, end.y) < 3 { scene.elements.remove(at: i); selection.removeAll(); return }
            tryBindLinearEndpoints(index: i)
        } else {
            // Normalize negative drags so width/height stay positive.
            if el.width < 0 { el.x += el.width; el.width = -el.width }
            if el.height < 0 { el.y += el.height; el.height = -el.height }
            if el.width < 3 && el.height < 3 { scene.elements.remove(at: i); selection.removeAll(); return }
            scene.elements[i] = el
        }
        tool = .select
        onChange?()
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

    // MARK: - Binding hooks (implemented in the binding phase)

    func reflowBoundArrows(movedIds: Set<String>) { ArrowBinding.reflow(&scene, movedIds: movedIds) }
    private func tryBindLinearEndpoints(index: Int) { ArrowBinding.bindEndpoints(&scene, arrowIndex: index) }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: // Esc
            if !selection.isEmpty || tool != .select { selection.removeAll(); tool = .select; needsDisplay = true }
            else { onDismiss?() }
            return
        case 51, 117: // Delete / Forward-delete
            if !selection.isEmpty { deleteSelection() }
            return
        default: break
        }
        if cmd, event.charactersIgnoringModifiers == "z" {
            if shift { redo() } else { undo() }; return
        }
        if cmd, event.charactersIgnoringModifiers == "a" {
            selection = Set(scene.elements.filter { !$0.locked }.map { $0.id }); needsDisplay = true; return
        }
        // Single-key tool shortcuts (Excalidraw-style).
        switch event.charactersIgnoringModifiers {
        case "v", "1": tool = .select
        case "r", "2": tool = .rectangle
        case "o", "4": tool = .ellipse
        case "d", "3": tool = .diamond
        case "l", "6": tool = .line
        case "a", "5": tool = .arrow
        case "t", "8": tool = .text
        default: super.keyDown(with: event)
        }
    }

    private func deleteSelection() {
        history.commit(scene.elements)
        scene.elements.removeAll { selection.contains($0.id) }
        // Also clear bindings that referenced deleted arrows/shapes.
        ArrowBinding.purge(&scene, deleted: selection)
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

    // MARK: - Pan / zoom

    override func scrollWheel(with event: NSEvent) {
        scene.scrollX += event.scrollingDeltaX / scene.zoom
        scene.scrollY += event.scrollingDeltaY / scene.zoom
        needsDisplay = true
    }

    /// Zoom around a screen anchor point (called from the app's pinch handler).
    func zoom(by factor: CGFloat, at screenPoint: CGPoint) {
        let before = scene.toWorld(screenPoint)
        scene.zoom = max(0.1, min(30, scene.zoom * factor))
        let after = scene.toWorld(screenPoint)
        scene.scrollX += after.x - before.x
        scene.scrollY += after.y - before.y
        needsDisplay = true
    }

    // MARK: - Camera helpers

    /// Fit all content (or the locked background) into the view.
    func recenter() {
        let target = scene.elements.first(where: { $0.locked })?.bounds ?? scene.contentBounds()
        guard let b = target, b.width > 0, b.height > 0 else {
            scene.scrollX = 0; scene.scrollY = 0; scene.zoom = 1; needsDisplay = true; return
        }
        let margin: CGFloat = 40
        let sx = (bounds.width - margin * 2) / b.width
        let sy = (bounds.height - margin * 2) / b.height
        scene.zoom = max(0.1, min(1, min(sx, sy)))
        scene.scrollX = (bounds.width / scene.zoom - b.width) / 2 - b.minX
        scene.scrollY = (bounds.height / scene.zoom - b.height) / 2 - b.minY
        needsDisplay = true
    }

    private func updateCursor() {
        (tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
    }
}
