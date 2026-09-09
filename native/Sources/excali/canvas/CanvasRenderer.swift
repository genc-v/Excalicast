import AppKit
import CoreGraphics
import CoreText

/// Draws a `Scene` into a `CGContext`. The same code path serves on-screen drawing and offscreen
/// PNG export — the caller sets up the context and passes the world→device scale via the scene's
/// camera (for export, a scene with zoom=1 and scroll chosen to frame the content).
enum CanvasRenderer {
    /// Draw the whole scene (background optional — export of a frozen shot wants it off so the image
    /// itself is the background). Selection chrome is drawn separately by the view in screen space.
    static func draw(_ scene: Scene, in ctx: CGContext, images: [String: CGImage],
                     drawBackground: Bool = true, backingScale: CGFloat = 1) {
        if drawBackground, let bg = Element.rgba(scene.backgroundColor) {
            ctx.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a)
            ctx.fill(ctx.boundingBoxOfClipPath)
        }
        for el in scene.elements {
            ctx.saveGState()
            ctx.setAlpha(el.opacity / 100)
            drawElement(el, in: ctx, scene: scene, images: images, backingScale: backingScale)
            ctx.restoreGState()
        }
    }

    private static func drawElement(_ el: Element, in ctx: CGContext, scene: Scene,
                                    images: [String: CGImage], backingScale: CGFloat) {
        let lineWidth = el.strokeWidth * scene.zoom
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        switch el.kind {
        case .rectangle, .ellipse, .diamond:
            let path = shapePath(el, scene: scene)
            if let fill = Element.rgba(el.backgroundColor) {
                ctx.setFillColor(red: fill.r, green: fill.g, blue: fill.b, alpha: fill.a)
                ctx.addPath(path); ctx.fillPath()
            }
            if let stroke = Element.rgba(el.strokeColor) {
                ctx.setStrokeColor(red: stroke.r, green: stroke.g, blue: stroke.b, alpha: stroke.a)
                ctx.addPath(path); ctx.strokePath()
            }
        case .line, .arrow:
            drawLinear(el, in: ctx, scene: scene)
        case .image:
            if let fileId = el.fileId, let img = images[fileId] {
                let r = screenRect(el.bounds, scene)
                ctx.saveGState()
                // CGImage draws bottom-up; flip within the element's rect (view is y-flipped).
                ctx.translateBy(x: r.minX, y: r.minY + r.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
                ctx.restoreGState()
            }
        case .text:
            drawText(el, in: ctx, scene: scene, backingScale: backingScale)
        }
    }

    // MARK: - Shapes

    private static func screenRect(_ world: CGRect, _ scene: Scene) -> CGRect {
        let o = scene.toScreen(CGPoint(x: world.minX, y: world.minY))
        return CGRect(x: o.x, y: o.y, width: world.width * scene.zoom, height: world.height * scene.zoom)
    }

    private static func shapePath(_ el: Element, scene: Scene) -> CGPath {
        let r = screenRect(el.bounds, scene)
        let p = CGMutablePath()
        switch el.kind {
        case .ellipse:
            p.addEllipse(in: r)
        case .diamond:
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
        default:
            let radius = min(12 * scene.zoom, min(r.width, r.height) / 4)
            p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        }
        return p
    }

    // MARK: - Line / arrow

    private static func drawLinear(_ el: Element, in ctx: CGContext, scene: Scene) {
        let pts = el.points.map { scene.toScreen(CGPoint(x: el.x + $0.x, y: el.y + $0.y)) }
        guard pts.count >= 2 else { return }
        guard let stroke = Element.rgba(el.strokeColor) else { return }
        ctx.setStrokeColor(red: stroke.r, green: stroke.g, blue: stroke.b, alpha: stroke.a)
        ctx.setFillColor(red: stroke.r, green: stroke.g, blue: stroke.b, alpha: stroke.a)

        ctx.beginPath()
        ctx.move(to: pts[0])
        if pts.count == 2 {
            ctx.addLine(to: pts[1])
        } else {
            // Smooth the polyline with a Catmull-Rom spline (converted to cubic béziers).
            for i in 0..<(pts.count - 1) {
                let p0 = i > 0 ? pts[i - 1] : pts[i]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                ctx.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
        ctx.strokePath()

        if el.kind == .arrow {
            drawArrowhead(from: pts[pts.count - 2], to: pts[pts.count - 1],
                          size: 14 * scene.zoom, in: ctx)
        }
    }

    private static func drawArrowhead(from a: CGPoint, to b: CGPoint, size: CGFloat, in ctx: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: b.x - size * cos(angle - spread), y: b.y - size * sin(angle - spread))
        let p2 = CGPoint(x: b.x - size * cos(angle + spread), y: b.y - size * sin(angle + spread))
        ctx.beginPath()
        ctx.move(to: b); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Text

    static func attributedString(_ el: Element, scale: CGFloat) -> NSAttributedString {
        let color = NSColor.fromHex(el.strokeColor) ?? .labelColor
        let font = NSFont(name: "Helvetica Neue", size: el.fontSize * scale)
            ?? NSFont.systemFont(ofSize: el.fontSize * scale)
        return NSAttributedString(string: el.text, attributes: [.font: font, .foregroundColor: color])
    }

    private static func drawText(_ el: Element, in ctx: CGContext, scene: Scene, backingScale: CGFloat) {
        guard !el.text.isEmpty else { return }
        let origin = scene.toScreen(CGPoint(x: el.x, y: el.y))
        let attr = attributedString(el, scale: scene.zoom)
        ctx.saveGState()
        // Core Text renders bottom-up; flip so text reads correctly in the y-flipped view.
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), nil)
        ctx.translateBy(x: origin.x, y: origin.y + size.height)
        ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// World-space size of a text element's content (for hit bounds + editor sizing).
    static func measureText(_ el: Element) -> CGSize {
        let attr = attributedString(el, scale: 1)
        let fs = CTFramesetterCreateWithAttributedString(attr)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), nil)
    }
}

extension NSColor {
    static func fromHex(_ s: String) -> NSColor? {
        guard let c = Element.rgba(s) else { return nil }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
