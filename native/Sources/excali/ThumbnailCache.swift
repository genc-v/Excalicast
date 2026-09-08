import AppKit
import ImageIO

/// Decodes downsampled thumbnails (via ImageIO) and caches them, so grid rendering and Quick Look
/// navigation don't re-decode full-resolution Retina PNGs on every keypress.
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

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
        cache.setObject(img, forKey: key)
        return img
    }
}
