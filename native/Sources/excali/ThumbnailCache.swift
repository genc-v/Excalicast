import AppKit
import ImageIO

/// Decodes downsampled thumbnails (via ImageIO) and caches them, so grid rendering and Quick Look
/// navigation don't re-decode full-resolution Retina PNGs on every keypress.
enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // Hard ceiling on decoded bitmaps: browsing many full-size (@1800 ≈ 8 MB each) previews
        // otherwise pins them all in RAM. Past this, NSCache evicts least-recently-used entries.
        c.totalCostLimit = 64 * 1024 * 1024 // ~64 MB
        return c
    }()

    static func image(path: String, maxPixel: CGFloat) -> NSImage? {
        let key = "\(path)@\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // Cost = decoded byte size so the limit above is measured in real memory, not object count.
        cache.setObject(img, forKey: key, cost: cg.width * cg.height * 4)
        return img
    }

    /// Release every cached bitmap. Called when the gallery closes so previews don't linger in RAM.
    static func clear() { cache.removeAllObjects() }
}
