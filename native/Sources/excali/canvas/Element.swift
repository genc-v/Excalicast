import CoreGraphics
import Foundation

/// The kinds of elements the native canvas supports. Matches the `type` string in the
/// `.excalidraw` file format so documents round-trip with the real Excalidraw app.
enum ElementKind: String, Codable {
    case rectangle, ellipse, diamond, line, arrow, text, image, freedraw
}

/// A binding from an arrow endpoint to a shape. `focus`/`gap` mirror Excalidraw's model so files
/// stay compatible: `focus` is a normalized offset across the shape, `gap` the distance from its edge.
struct Binding: Equatable {
    var elementId: String
    var focus: Double = 0
    var gap: Double = 8
    // Where the arrow attached, normalized to the shape's half-extents (−1…1). Lets several arrows
    // connect to one shape at distinct points instead of all collapsing to the center.
    var anchorX: Double = 0
    var anchorY: Double = 0
}

/// A single drawable element. One value type covers every kind; unused fields stay at their
/// defaults (e.g. `points` only matters for line/arrow, `text` only for text).
struct Element: Identifiable, Equatable {
    var id: String = Element.newId()
    var kind: ElementKind

    // Geometry. For line/arrow, (x,y) is the element origin and `points` are relative to it; for
    // everything else (x,y,width,height) is the axis-aligned bounding box. `angle` is unused in the
    // MVP (no rotation) but kept for format fidelity.
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
    var angle: CGFloat = 0

    // Style.
    var strokeColor: String = "#1e1e1e"
    var backgroundColor: String = "transparent"
    var strokeWidth: CGFloat = 2
    var opacity: CGFloat = 100

    // Line / arrow.
    var points: [CGPoint] = []
    var startBinding: Binding?
    var endBinding: Binding?
    var startArrowhead: String?
    var endArrowhead: String? = nil

    // Shapes that have arrows bound to them list those arrow ids here (Excalidraw's `boundElements`).
    var boundElements: [String] = []

    // Text.
    var text: String = ""
    var fontSize: CGFloat = 20
    var fontFamily: Int = 1 // matches Excalidraw's font id; unused natively beyond persistence
    var textAlign: String = "left" // left | center | right
    var containerId: String? // if set, this text is bound inside a shape / to a line's midpoint

    // Image (the locked frozen-screenshot background).
    var fileId: String?
    var locked: Bool = false

    /// Axis-aligned bounds in world space. For point-based kinds this is derived from `points`.
    var bounds: CGRect {
        if usesPoints, !points.isEmpty {
            let xs = points.map { x + $0.x }
            let ys = points.map { y + $0.y }
            let minX = xs.min() ?? x, maxX = xs.max() ?? x
            let minY = ys.min() ?? y, maxY = ys.max() ?? y
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Center of the element's bounds in world space.
    var center: CGPoint { let b = bounds; return CGPoint(x: b.midX, y: b.midY) }

    var isLinear: Bool { kind == .line || kind == .arrow }
    /// Kinds whose geometry is a list of `points` (relative to x,y).
    var usesPoints: Bool { kind == .line || kind == .arrow || kind == .freedraw }

    /// A short unique id (nanoid-ish) compatible with Excalidraw's string ids.
    static func newId() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var s = ""
        var g = SystemRandomNumberGenerator()
        for _ in 0..<21 { s.append(alphabet[Int.random(in: 0..<alphabet.count, using: &g)]) }
        return s
    }
}

/// Parse a `#rrggbb` / `#rrggbbaa` / "transparent" color string into an NSColor-friendly RGBA.
extension Element {
    static func rgba(_ s: String) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        if s == "transparent" { return nil }
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let val = UInt64(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            return (CGFloat((val >> 16) & 0xff) / 255, CGFloat((val >> 8) & 0xff) / 255,
                    CGFloat(val & 0xff) / 255, 1)
        case 8:
            return (CGFloat((val >> 24) & 0xff) / 255, CGFloat((val >> 16) & 0xff) / 255,
                    CGFloat((val >> 8) & 0xff) / 255, CGFloat(val & 0xff) / 255)
        default:
            return nil
        }
    }
}
