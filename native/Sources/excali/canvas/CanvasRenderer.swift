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
        // Grid (whiteboards only — not over a frozen screenshot).
        if scene.gridEnabled, !scene.elements.contains(where: { $0.locked }) {
            drawGrid(scene, in: ctx)
        }
        // Bound labels (text attached to a line/arrow) render last so no other line crosses them.
        func isBoundLabel(_ el: Element) -> Bool { el.kind == .text && el.containerId != nil }
        for el in scene.elements where !isBoundLabel(el) {
            ctx.saveGState()
            ctx.setAlpha(el.opacity / 100)
            drawElement(el, in: ctx, scene: scene, images: images, backingScale: backingScale)
            ctx.restoreGState()
        }
        for el in scene.elements where isBoundLabel(el) {
            ctx.saveGState()
            ctx.setAlpha(el.opacity / 100)
            drawElement(el, in: ctx, scene: scene, images: images, backingScale: backingScale)
            ctx.restoreGState()
        }
    }

    /// A faint grid at 20pt world spacing, aligned to the camera. Skipped when zoomed too far out.
    private static func drawGrid(_ scene: Scene, in ctx: CGContext) {
        let spacing = 20 * scene.zoom
        guard spacing > 4 else { return }
        let clip = ctx.boundingBoxOfClipPath
        // Grid contrasts with the canvas: light lines on a dark canvas, dark on a light one.
        let dark = (Element.rgba(scene.backgroundColor)?.r ?? 1) < 0.5
        let v: CGFloat = dark ? 1 : 0
        ctx.setStrokeColor(red: v, green: v, blue: v, alpha: dark ? 0.16 : 0.12)
        ctx.setLineWidth(1)

        let offX = (scene.scrollX * scene.zoom).truncatingRemainder(dividingBy: spacing)
        let offY = (scene.scrollY * scene.zoom).truncatingRemainder(dividingBy: spacing)
        ctx.beginPath()
        var x = clip.minX + offX.truncatingRemainder(dividingBy: spacing)
        while x <= clip.maxX { ctx.move(to: CGPoint(x: x, y: clip.minY)); ctx.addLine(to: CGPoint(x: x, y: clip.maxY)); x += spacing }
        var y = clip.minY + offY.truncatingRemainder(dividingBy: spacing)
        while y <= clip.maxY { ctx.move(to: CGPoint(x: clip.minX, y: y)); ctx.addLine(to: CGPoint(x: clip.maxX, y: y)); y += spacing }
        ctx.strokePath()
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
        case .freedraw:
            drawFreedraw(el, in: ctx, scene: scene)
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
            let headSize = (12 + el.strokeWidth * 2) * scene.zoom
            drawArrowhead(from: pts[pts.count - 2], to: pts[pts.count - 1], size: headSize, in: ctx)
        }
    }

    /// A freehand pen stroke: a smoothed path through all sampled points, round caps/joins.
    private static func drawFreedraw(_ el: Element, in ctx: CGContext, scene: Scene) {
        let pts = el.points.map { scene.toScreen(CGPoint(x: el.x + $0.x, y: el.y + $0.y)) }
        guard let stroke = Element.rgba(el.strokeColor) else { return }
        ctx.setStrokeColor(red: stroke.r, green: stroke.g, blue: stroke.b, alpha: stroke.a)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)

        if pts.count < 2 {
            // A single tap = a dot.
            if let p = pts.first {
                ctx.setFillColor(red: stroke.r, green: stroke.g, blue: stroke.b, alpha: stroke.a)
                let r = max(1, el.strokeWidth * scene.zoom) / 2
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
            return
        }
        ctx.beginPath()
        ctx.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            ctx.addCurve(to: p2, control1: c1, control2: c2)
        }
        ctx.strokePath()
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
        let para = NSMutableParagraphStyle()
        switch el.textAlign {
        case "center": para.alignment = .center
        case "right": para.alignment = .right
        default: para.alignment = .left
        }
        return NSAttributedString(string: el.text,
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    private static func drawText(_ el: Element, in ctx: CGContext, scene: Scene, backingScale: CGFloat) {
        guard !el.text.isEmpty else { return }
        let origin = scene.toScreen(CGPoint(x: el.x, y: el.y))
        let attr = attributedString(el, scale: scene.zoom)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), nil)

        // A label bound to a line/arrow gets a background swatch (canvas color) so the line doesn't
        // run through the text.
        if let cid = el.containerId, let container = scene.element(id: cid), container.isLinear,
           let bg = Element.rgba(scene.backgroundColor) {
            let pad: CGFloat = 5 * scene.zoom
            let rect = CGRect(x: origin.x - pad, y: origin.y - pad,
                              width: size.width + pad * 2, height: size.height + pad * 2)
            let r = min(6 * scene.zoom, rect.height / 2)
            ctx.setFillColor(red: bg.r, green: bg.g, blue: bg.b, alpha: bg.a)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }

        ctx.saveGState()
        // Core Text renders bottom-up; flip so text reads correctly in the y-flipped view.
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
