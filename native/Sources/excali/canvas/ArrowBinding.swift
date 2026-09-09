import CoreGraphics
import Foundation

/// Arrow↔shape binding: attach an arrow endpoint to a shape so it reflows when the shape moves.
/// Mirrors Excalidraw's `{elementId, focus, gap}` model closely enough that files round-trip.
enum ArrowBinding {
    /// Items an arrow can bind to: any shape/text/image, except linear elements and the locked
    /// screenshot background.
    private static func isBindable(_ el: Element) -> Bool {
        if el.locked || el.isLinear { return false }
        switch el.kind {
        case .rectangle, .ellipse, .diamond, .text, .image: return true
        default: return false
        }
    }

    /// After an arrow is drawn, bind either endpoint that lands on/near a shape.
    static func bindEndpoints(_ scene: inout Scene, arrowIndex i: Int) {
        guard scene.elements.indices.contains(i), scene.elements[i].isLinear,
              scene.elements[i].points.count >= 2 else { return }
        let arrow = scene.elements[i]
        let last = arrow.points.count - 1
        let startWorld = CGPoint(x: arrow.x + arrow.points[0].x, y: arrow.y + arrow.points[0].y)
        let endWorld = CGPoint(x: arrow.x + arrow.points[last].x, y: arrow.y + arrow.points[last].y)

        if let s = shape(at: startWorld, in: scene, excluding: arrow.id) {
            let (ax, ay) = anchor(of: s, at: startWorld)
            scene.elements[i].startBinding = Binding(elementId: s.id, gap: 8, anchorX: ax, anchorY: ay)
            addBound(&scene, shapeId: s.id, arrowId: arrow.id)
        }
        if let e = shape(at: endWorld, in: scene, excluding: arrow.id) {
            let (ax, ay) = anchor(of: e, at: endWorld)
            scene.elements[i].endBinding = Binding(elementId: e.id, gap: 8, anchorX: ax, anchorY: ay)
            addBound(&scene, shapeId: e.id, arrowId: arrow.id)
        }
        recompute(&scene, arrowIndex: i)
    }

    /// Reflow every arrow bound to any of the moved shapes (and reflow moved arrows themselves).
    static func reflow(_ scene: inout Scene, movedIds: Set<String>) {
        var toReflow = Set<String>()
        for id in movedIds {
            guard let el = scene.element(id: id) else { continue }
            if el.isLinear { toReflow.insert(el.id) }
            for arrowId in el.boundElements { toReflow.insert(arrowId) }
        }
        for id in toReflow {
            if let i = scene.index(of: id) { recompute(&scene, arrowIndex: i) }
        }
    }

    /// Recompute a bound arrow's endpoints so they sit on the boundaries of the shapes they attach
    /// to. Intermediate bend points are preserved.
    private static func recompute(_ scene: inout Scene, arrowIndex i: Int) {
        guard scene.elements.indices.contains(i), scene.elements[i].isLinear,
              scene.elements[i].points.count >= 2 else { return }
        var arrow = scene.elements[i]
        // Work in world space.
        var world = arrow.points.map { CGPoint(x: arrow.x + $0.x, y: arrow.y + $0.y) }
        let last = world.count - 1

        if let b = arrow.startBinding, let shape = scene.element(id: b.elementId) {
            world[0] = HitTest.boundaryPoint(of: shape, toward: aim(shape, b, fallback: world[1]), gap: b.gap)
        }
        if let b = arrow.endBinding, let shape = scene.element(id: b.elementId) {
            world[last] = HitTest.boundaryPoint(of: shape, toward: aim(shape, b, fallback: world[last - 1]), gap: b.gap)
        }
        // Re-anchor origin at the first point; points become relative.
        let origin = world[0]
        arrow.x = origin.x; arrow.y = origin.y
        arrow.points = world.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        let b = arrow.bounds
        arrow.width = b.width; arrow.height = b.height
        scene.elements[i] = arrow
    }

    /// Drop bindings that reference deleted elements, and remove deleted arrows from shapes'
    /// `boundElements` lists.
    static func purge(_ scene: inout Scene, deleted: Set<String>) {
        for i in scene.elements.indices {
            if let b = scene.elements[i].startBinding, deleted.contains(b.elementId) {
                scene.elements[i].startBinding = nil
            }
            if let b = scene.elements[i].endBinding, deleted.contains(b.elementId) {
                scene.elements[i].endBinding = nil
            }
            scene.elements[i].boundElements.removeAll { deleted.contains($0) }
        }
    }

    // MARK: - Helpers

    /// Normalized drop position within a shape (−1…1 across its half-extents), clamped.
    private static func anchor(of shape: Element, at p: CGPoint) -> (Double, Double) {
        let hw = max(shape.bounds.width / 2, 1), hh = max(shape.bounds.height / 2, 1)
        let nx = Double((p.x - shape.center.x) / hw)
        let ny = Double((p.y - shape.center.y) / hh)
        return (max(-1, min(1, nx)), max(-1, min(1, ny)))
    }

    /// The world point a bound endpoint should aim at: the stored anchor direction if meaningful,
    /// else fall back to the arrow's other endpoint (center-ish drops behave as before).
    private static func aim(_ shape: Element, _ b: Binding, fallback: CGPoint) -> CGPoint {
        if hypot(b.anchorX, b.anchorY) < 0.15 { return fallback }
        let hw = shape.bounds.width / 2, hh = shape.bounds.height / 2
        return CGPoint(x: shape.center.x + CGFloat(b.anchorX) * hw,
                       y: shape.center.y + CGFloat(b.anchorY) * hh)
    }

    private static func shape(at p: CGPoint, in scene: Scene, excluding id: String) -> Element? {
        for el in scene.elements.reversed() where el.id != id && isBindable(el) {
            if HitTest.hits(el, p, tolerance: 12) { return el }
        }
        return nil
    }

    /// The bindable item an arrow endpoint at `p` would attach to — used to highlight it while
    /// drawing/dragging.
    static func target(at p: CGPoint, in scene: Scene, excluding id: String) -> Element? {
        shape(at: p, in: scene, excluding: id)
    }

    private static func addBound(_ scene: inout Scene, shapeId: String, arrowId: String) {
        guard let i = scene.index(of: shapeId) else { return }
        if !scene.elements[i].boundElements.contains(arrowId) {
            scene.elements[i].boundElements.append(arrowId)
        }
    }
}
