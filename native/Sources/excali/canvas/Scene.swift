import CoreGraphics
import Foundation

/// The document + camera. Elements are drawn in array order (last = topmost). The camera maps world
/// space (element coordinates) to screen space: `screen = (world + scroll) * zoom`.
struct Scene {
    var elements: [Element] = []
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    var zoom: CGFloat = 1
    var backgroundColor: String = "#ffffff"
    var gridEnabled: Bool = false

    // MARK: - Coordinate transforms

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x + scrollX) * zoom, y: (p.y + scrollY) * zoom)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom - scrollX, y: p.y / zoom - scrollY)
    }

    // MARK: - Lookup

    func element(id: String) -> Element? { elements.first { $0.id == id } }
    func index(of id: String) -> Int? { elements.firstIndex { $0.id == id } }

    /// Bounds enclosing every element, in world space (nil if empty).
    func contentBounds() -> CGRect? {
        guard !elements.isEmpty else { return nil }
        return elements.dropFirst().reduce(elements[0].bounds) { $0.union($1.bounds) }
    }
}

/// A simple snapshot-based undo/redo stack over the element list.
final class History {
    private var undoStack: [[Element]] = []
    private var redoStack: [[Element]] = []
    private let limit = 80

    /// Record the current state *before* a mutation.
    func commit(_ elements: [Element]) {
        undoStack.append(elements)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo(current: [Element]) -> [Element]? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return prev
    }

    func redo(current: [Element]) -> [Element]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    func clear() { undoStack.removeAll(); redoStack.removeAll() }
}
