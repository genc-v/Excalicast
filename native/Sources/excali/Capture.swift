import AppKit
import CoreGraphics
import ScreenCaptureKit

struct CaptureResult {
    let dataUrl: String
    let widthPx: Int
    let heightPx: Int
    let scaleFactor: Double
    let logicalW: Double
    let logicalH: Double
    let looksBlack: Bool

    /// JSON-serializable dictionary for the WKWebView reply (camelCase to match the TS interface).
    var dict: [String: Any] {
        [
            "dataUrl": dataUrl,
            "widthPx": widthPx,
            "heightPx": heightPx,
            "scaleFactor": scaleFactor,
            "logicalW": logicalW,
            "logicalH": logicalH,
            "looksBlack": looksBlack,
        ]
    }
}

enum Capture {
    // ScreenCaptureKit's first `SCShareableContent` fetch is slow (framework init + window
    // enumeration). We warm it at launch and reuse the cached display list so ⌘⇧A opens fast; each
    // use kicks a background refresh for the next time.
    private static var cachedContent: SCShareableContent?

    /// Warm ScreenCaptureKit at launch so the first capture isn't slow.
    static func prewarm() {
        Task { cachedContent = try? await fetchContent() }
    }

    private static func fetchContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    /// Cached shareable content when available (refreshing in the background), else a fresh fetch.
    private static func shareableContent() async throws -> SCShareableContent {
        if let c = cachedContent {
            Task { cachedContent = try? await fetchContent() }
            return c
        }
        let c = try await fetchContent()
        cachedContent = c
        return c
    }

    /// The NSScreen under the mouse cursor (falls back to main).
    static func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Capture the display under the cursor as a PNG data URL + geometry.
    static func captureUnderCursor() async throws -> CaptureResult {
        let screen = screenUnderCursor()
        let scale = Double(screen.backingScaleFactor)
        let logicalW = Double(screen.frame.width)
        let logicalH = Double(screen.frame.height)
        let pxW = Int((logicalW * scale).rounded())
        let pxH = Int((logicalH * scale).rounded())

        let content = try await shareableContent()
        let targetID = displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == targetID })
            ?? content.displays.first
        else {
            throw NSError(domain: "excali", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pxW
        config.height = pxH
        config.showsCursor = false
        config.scalesToFit = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "excali", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
        }
        let dataUrl = "data:image/png;base64," + png.base64EncodedString()

        return CaptureResult(
            dataUrl: dataUrl,
            widthPx: cgImage.width,
            heightPx: cgImage.height,
            scaleFactor: scale,
            logicalW: logicalW,
            logicalH: logicalH,
            looksBlack: isBlack(cgImage)
        )
    }

    /// Downscale to 16x16 and report blank only if essentially every pixel is black — a truly
    /// black frame means missing permission or DRM-protected content, not a dark app.
    private static func isBlack(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var black = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] < 8, pixels[i + 1] < 8, pixels[i + 2] < 8 { black += 1 }
        }
        return Double(black) / Double(side * side) > 0.995
    }
}
