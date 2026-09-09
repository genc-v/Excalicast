import AppKit
import CoreGraphics
import Foundation

/// Reads/writes the `.excalidraw` JSON format and exports the scene to PNG. Dictionary-based
/// (JSONSerialization) rather than strict Codable so we tolerate the many optional fields real
/// Excalidraw writes, and emit sane defaults so our files open cleanly in the real app.
enum ExcalidrawIO {
    // MARK: - Write

    static func fileData(_ scene: Scene, images: [String: CGImage],
                         dataURLs: [String: String] = [:]) -> Data? {
        var elementDicts: [[String: Any]] = []
        var files: [String: Any] = [:]
        var kindOf: [String: ElementKind] = [:]
        for el in scene.elements { kindOf[el.id] = el.kind }

        for el in scene.elements {
            elementDicts.append(elementDict(el, kindOf: kindOf))
            if el.kind == .image, let fid = el.fileId {
                // Prefer the cached dataURL (from capture/open) so we don't re-encode a full-res
                // screenshot on every save; only fall back to encoding if we somehow lack it.
                if let dataURL = dataURLs[fid] ?? images[fid].flatMap(pngDataURL) {
                    files[fid] = [
                        "mimeType": "image/png", "id": fid, "dataURL": dataURL,
                        "created": 0, "lastRetrieved": 0,
                    ]
                }
            }
        }

        let doc: [String: Any] = [
            "type": "excalidraw",
            "version": 2,
            "source": "excalicast-native",
            "elements": elementDicts,
            "appState": [
                "viewBackgroundColor": scene.backgroundColor,
                "gridModeEnabled": scene.gridEnabled,
            ],
            "files": files,
        ]
        return try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted])
    }

    private static func elementDict(_ el: Element, kindOf: [String: ElementKind]) -> [String: Any] {
        var d: [String: Any] = [
            "id": el.id,
            "type": el.kind.rawValue,
            "x": el.x, "y": el.y, "width": el.width, "height": el.height,
            "angle": el.angle,
            "strokeColor": el.strokeColor,
            "backgroundColor": el.backgroundColor,
            "fillStyle": "solid",
            "strokeWidth": el.strokeWidth,
            "strokeStyle": "solid",
            "roughness": 0, // 0 = clean (architect) strokes
            "opacity": el.opacity,
            "groupIds": [],
            "frameId": NSNull(),
            "roundness": NSNull(),
            "seed": Int.random(in: 1...2_000_000_000),
            "version": 1,
            "versionNonce": Int.random(in: 1...2_000_000_000),
            "isDeleted": false,
            "boundElements": el.boundElements.map {
                ["id": $0, "type": (kindOf[$0] == .text ? "text" : "arrow")]
            },
            "updated": 1,
            "link": NSNull(),
            "locked": el.locked,
        ]
        if el.isLinear {
            d["points"] = el.points.map { [$0.x, $0.y] }
            d["lastCommittedPoint"] = NSNull()
            d["startArrowhead"] = el.startArrowhead as Any? ?? NSNull()
            d["endArrowhead"] = el.endArrowhead as Any? ?? NSNull()
            d["startBinding"] = bindingDict(el.startBinding)
            d["endBinding"] = bindingDict(el.endBinding)
        }
        if el.kind == .text {
            d["text"] = el.text
            d["originalText"] = el.text
            d["fontSize"] = el.fontSize
            d["fontFamily"] = el.fontFamily
            d["textAlign"] = el.containerId != nil ? "center" : "left"
            d["verticalAlign"] = el.containerId != nil ? "middle" : "top"
            d["lineHeight"] = 1.25
            d["baseline"] = el.fontSize
            d["containerId"] = el.containerId as Any? ?? NSNull()
        }
        if el.kind == .image, let fid = el.fileId {
            d["fileId"] = fid
            d["status"] = "saved"
            d["scale"] = [1, 1]
        }
        return d
    }

    private static func bindingDict(_ b: Binding?) -> Any {
        guard let b = b else { return NSNull() }
        return ["elementId": b.elementId, "focus": b.focus, "gap": b.gap]
    }

    // MARK: - Read

    /// Parse a document into (elements, decoded images, original dataURLs). Unknown kinds are skipped.
    static func parse(_ data: Data) -> (elements: [Element], images: [String: CGImage], dataURLs: [String: String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [:], [:])
        }
        var images: [String: CGImage] = [:]
        var dataURLs: [String: String] = [:]
        if let files = root["files"] as? [String: Any] {
            for (fid, v) in files {
                if let f = v as? [String: Any], let url = f["dataURL"] as? String,
                   let img = decodeDataURL(url) {
                    images[fid] = img
                    dataURLs[fid] = url
                }
            }
        }
        var out: [Element] = []
        for raw in (root["elements"] as? [[String: Any]] ?? []) {
            if let el = element(from: raw) { out.append(el) }
        }
        return (out, images, dataURLs)
    }

    private static func element(from d: [String: Any]) -> Element? {
        guard let typeStr = d["type"] as? String, let kind = ElementKind(rawValue: typeStr) else {
            return nil
        }
        func f(_ k: String) -> CGFloat { (d[k] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0 }
        var el = Element(kind: kind)
        el.id = d["id"] as? String ?? Element.newId()
        el.x = f("x"); el.y = f("y"); el.width = f("width"); el.height = f("height"); el.angle = f("angle")
        el.strokeColor = d["strokeColor"] as? String ?? "#1e1e1e"
        el.backgroundColor = d["backgroundColor"] as? String ?? "transparent"
        el.strokeWidth = (d["strokeWidth"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 2
        el.opacity = (d["opacity"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 100
        el.locked = d["locked"] as? Bool ?? false
        if let pts = d["points"] as? [[NSNumber]] {
            el.points = pts.map { CGPoint(x: CGFloat(truncating: $0[0]), y: CGFloat(truncating: $0[1])) }
        }
        el.startBinding = binding(d["startBinding"])
        el.endBinding = binding(d["endBinding"])
        el.startArrowhead = d["startArrowhead"] as? String
        el.endArrowhead = d["endArrowhead"] as? String
        if let bound = d["boundElements"] as? [[String: Any]] {
            el.boundElements = bound.compactMap { $0["id"] as? String }
        }
        el.text = d["text"] as? String ?? ""
        el.fontSize = (d["fontSize"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 20
        el.fontFamily = d["fontFamily"] as? Int ?? 1
        el.containerId = d["containerId"] as? String
        el.fileId = d["fileId"] as? String
        return el
    }

    private static func binding(_ v: Any?) -> Binding? {
        guard let d = v as? [String: Any], let id = d["elementId"] as? String else { return nil }
        let focus = (d["focus"] as? NSNumber).map { Double(truncating: $0) } ?? 0
        let gap = (d["gap"] as? NSNumber).map { Double(truncating: $0) } ?? 8
        return Binding(elementId: id, focus: focus, gap: gap)
    }

    // MARK: - PNG

    /// Render the scene to PNG bytes. Frames the locked background if present (frozen mode), else all
    /// content. Returns nil if there's nothing to export.
    static func exportPNG(_ scene: Scene, images: [String: CGImage], scale: CGFloat = 2) -> Data? {
        let hasLocked = scene.elements.contains { $0.locked && $0.kind == .image }
        let frame = scene.elements.first(where: { $0.locked })?.bounds ?? scene.contentBounds()
        guard let b = frame, b.width >= 1, b.height >= 1 else { return nil }

        let w = Int((b.width * scale).rounded()), h = Int((b.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Flip to a top-left/y-down space so the renderer (written for the flipped NSView) matches.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        var ex = scene
        ex.zoom = scale; ex.scrollX = -b.minX; ex.scrollY = -b.minY
        CanvasRenderer.draw(ex, in: ctx, images: images, drawBackground: !hasLocked, backingScale: scale)

        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func pngDataURL(_ img: CGImage) -> String? {
        guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func decodeDataURL(_ s: String) -> CGImage? {
        let raw = s.hasPrefix("data:") ? String(s.drop(while: { $0 != "," }).dropFirst()) : s
        guard let data = Data(base64Encoded: raw), let rep = NSBitmapImageRep(data: data) else {
            return nil
        }
        return rep.cgImage
    }
}
