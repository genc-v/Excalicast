import AppKit

// Render the menu-bar glyph (pencil.tip.crop.circle) in white on a purple squircle at 1024px.
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: image.size)
    image.draw(in: r)
    r.fill(using: .sourceAtop)
    out.unlockFocus()
    out.isTemplate = false
    return out
}

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Background: rounded-rect (squircle-ish) purple gradient, matching Excalidraw's brand color.
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
path.addClip()
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.443, green: 0.431, blue: 0.882, alpha: 1), // #7169e1
    NSColor(srgbRed: 0.353, green: 0.341, blue: 0.816, alpha: 1), // #5a57d0
])!
grad.draw(in: rect, angle: -90)

// Glyph, white, centered at ~58% of the canvas.
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.58, weight: .regular)
if let base = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let glyph = tinted(base, .white)
    let gs = glyph.size
    let gr = NSRect(x: (size - gs.width) / 2, y: (size - gs.height) / 2, width: gs.width, height: gs.height)
    glyph.draw(in: gr)
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
