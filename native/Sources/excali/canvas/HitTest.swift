import CoreGraphics
import Foundation

/// Geometry helpers: point/rect hit-testing per element kind, plus boundary intersection used by
/// arrow binding. All in world space.
enum HitTest {
    /// Distance from point `p` to segment a–b.
    static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    /// Does `p` (world) hit `el`? `tolerance` is in world units (already divided by zoom by caller).
    static func hits(_ el: Element, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch el.kind {
        case .rectangle, .image, .text:
            let b = el.bounds.insetBy(dx: -tolerance, dy: -tolerance)
            // Filled/opaque kinds hit anywhere inside; unfilled rects still hit inside for usability.
            return b.contains(p)
        case .ellipse:
            let b = el.bounds
            guard b.width > 0, b.height > 0 else { return false }
            let nx = (p.x - b.midX) / (b.width / 2 + tolerance)
            let ny = (p.y - b.midY) / (b.height / 2 + tolerance)
            return nx * nx + ny * ny <= 1
        case .diamond:
            let b = el.bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard b.width > 0, b.height > 0 else { return false }
            let nx = abs(p.x - b.midX) / (b.width / 2)
            let ny = abs(p.y - b.midY) / (b.height / 2)
            return nx + ny <= 1
        case .line, .arrow, .freedraw:
            let pts = el.points.map { CGPoint(x: el.x + $0.x, y: el.y + $0.y) }
            guard pts.count >= 2 else { return false }
            for i in 0..<(pts.count - 1) {
                if distanceToSegment(p, pts[i], pts[i + 1]) <= tolerance + el.strokeWidth {
                    return true
                }
            }
            return false
        }
    }

    /// The point halfway *along* a polyline (by arc length) — where a line/arrow's label belongs,
    /// which sits on the actual path even when it's bent.
    static func midpointAlong(_ pts: [CGPoint]) -> CGPoint {
        guard pts.count >= 2 else { return pts.first ?? .zero }
        var total: CGFloat = 0
        for i in 0..<(pts.count - 1) { total += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) }
        var half = total / 2
        for i in 0..<(pts.count - 1) {
            let len = hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y)
            if half <= len {
                let t = len > 0 ? half / len : 0
                return CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * t,
                               y: pts[i].y + (pts[i + 1].y - pts[i].y) * t)
            }
            half -= len
        }
        return pts.last ?? .zero
    }

    /// Whether a marquee rect actually crosses a linear element's path (not just its bounding box).
    static func rectIntersectsLinear(_ rect: CGRect, _ el: Element) -> Bool {
        let pts = el.points.map { CGPoint(x: el.x + $0.x, y: el.y + $0.y) }
        guard pts.count >= 2 else { return false }
        for i in 0..<(pts.count - 1) where rectIntersectsSegment(rect, pts[i], pts[i + 1]) { return true }
        return false
    }

    private static func rectIntersectsSegment(_ r: CGRect, _ a: CGPoint, _ b: CGPoint) -> Bool {
        if r.contains(a) || r.contains(b) { return true }
        let tl = CGPoint(x: r.minX, y: r.minY), tr = CGPoint(x: r.maxX, y: r.minY)
        let br = CGPoint(x: r.maxX, y: r.maxY), bl = CGPoint(x: r.minX, y: r.maxY)
        return segmentsCross(a, b, tl, tr) || segmentsCross(a, b, tr, br)
            || segmentsCross(a, b, br, bl) || segmentsCross(a, b, bl, tl)
    }

    private static func segmentsCross(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            (c.y - a.y) * (b.x - a.x) > (b.y - a.y) * (c.x - a.x)
        }
        return ccw(p1, p3, p4) != ccw(p2, p3, p4) && ccw(p1, p2, p3) != ccw(p1, p2, p4)
    }

    /// Topmost element (reverse z-order) hit by `p`, if any.
    static func topmost(_ elements: [Element], _ p: CGPoint, tolerance: CGFloat) -> Element? {
        for el in elements.reversed() where !el.locked {
            if hits(el, p, tolerance: tolerance) { return el }
        }
        return nil
    }

    /// Intersection of the ray from the shape center toward `target` with the shape's boundary,
    /// pushed out by `gap`. Used to anchor a bound arrow endpoint on the edge of a shape.
    static func boundaryPoint(of el: Element, toward target: CGPoint, gap: CGFloat) -> CGPoint {
        let c = el.center
        let dir = CGPoint(x: target.x - c.x, y: target.y - c.y)
        let len = hypot(dir.x, dir.y)
        guard len > 0.0001 else { return c }
        let u = CGPoint(x: dir.x / len, y: dir.y / len)
        let b = el.bounds
        let hw = b.width / 2, hh = b.height / 2

        // Parametric distance `t` from center to the boundary along `u`, per shape.
        let t: CGFloat
        switch el.kind {
        case .ellipse:
            let denom = (u.x * u.x) / (hw * hw) + (u.y * u.y) / (hh * hh)
            t = denom > 0 ? 1 / sqrt(denom) : 0
        case .diamond:
            let denom = abs(u.x) / hw + abs(u.y) / hh
            t = denom > 0 ? 1 / denom : 0
        default: // rectangle / image / text — box edge
            let tx = hw / max(abs(u.x), 0.0001)
            let ty = hh / max(abs(u.y), 0.0001)
            t = min(tx, ty)
        }
        return CGPoint(x: c.x + u.x * (t + gap), y: c.y + u.y * (t + gap))
    }
}
