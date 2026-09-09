import CoreGraphics
import Foundation

/// Arrow↔shape binding: attach an arrow endpoint to a shape so it reflows when the shape moves.
/// Mirrors Excalidraw's `{elementId, focus, gap}` model closely enough that files round-trip.
enum ArrowBinding {
    /// Shapes an arrow can bind to (not other lines/arrows/text).
    private static func isBindable(_ el: Element) -> Bool {
        switch el.kind {
        case .rectangle, .ellipse, .diamond: return true
        default: return false
        }
    }

    /// After an arrow is drawn, bind either endpoint that lands on/near a shape.
    static func bindEndpoints(_ scene: inout Scene, arrowIndex i: Int) {
        guard scene.elements.indices.contains(i), scene.elements[i].isLinear else { return }
        let arrow = scene.elements[i]
        let startWorld = CGPoint(x: arrow.x + arrow.points[0].x, y: arrow.y + arrow.points[0].y)
        let endWorld = CGPoint(x: arrow.x + arrow.points[1].x, y: arrow.y + arrow.points[1].y)

        if let s = shape(at: startWorld, in: scene, excluding: arrow.id) {
            scene.elements[i].startBinding = Binding(elementId: s.id, gap: 8)
            addBound(&scene, shapeId: s.id, arrowId: arrow.id)
        }
        if let e = shape(at: endWorld, in: scene, excluding: arrow.id) {
            scene.elements[i].endBinding = Binding(elementId: e.id, gap: 8)
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

    /// Recompute a bound arrow's endpoints so they sit on the boundaries of the shapes they attach to.
    private static func recompute(_ scene: inout Scene, arrowIndex i: Int) {
        guard scene.elements.indices.contains(i), scene.elements[i].isLinear else { return }
        var arrow = scene.elements[i]
        var start = CGPoint(x: arrow.x + arrow.points[0].x, y: arrow.y + arrow.points[0].y)
        var end = CGPoint(x: arrow.x + arrow.points[1].x, y: arrow.y + arrow.points[1].y)

        if let b = arrow.startBinding, let shape = scene.element(id: b.elementId) {
            start = HitTest.boundaryPoint(of: shape, toward: end, gap: b.gap)
        }
        if let b = arrow.endBinding, let shape = scene.element(id: b.elementId) {
            end = HitTest.boundaryPoint(of: shape, toward: start, gap: b.gap)
        }
        // Re-anchor the element origin at `start`; points become relative to it.
        arrow.x = start.x
        arrow.y = start.y
        arrow.points = [CGPoint(x: 0, y: 0), CGPoint(x: end.x - start.x, y: end.y - start.y)]
        arrow.width = abs(end.x - start.x)
        arrow.height = abs(end.y - start.y)
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

    private static func shape(at p: CGPoint, in scene: Scene, excluding id: String) -> Element? {
        for el in scene.elements.reversed() where el.id != id && isBindable(el) {
            if HitTest.hits(el, p, tolerance: 12) { return el }
        }
        return nil
    }

    private static func addBound(_ scene: inout Scene, shapeId: String, arrowId: String) {
        guard let i = scene.index(of: shapeId) else { return }
        if !scene.elements[i].boundElements.contains(arrowId) {
            scene.elements[i].boundElements.append(arrowId)
        }
    }
}
