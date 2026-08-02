// Renders the muxy app icon: carbon square, orange prompt chevron.
// Usage: swift Scripts/make-icon.swift <iconset-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let bg = NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
        xRadius: s * 0.22, yRadius: s * 0.22
    )
    NSColor(srgbRed: 0x0F / 255, green: 0x0F / 255, blue: 0x0F / 255, alpha: 1).setFill()
    bg.fill()

    let text = "❯" as NSString
    let font = NSFont.monospacedSystemFont(ofSize: s * 0.5, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 1.0, green: 0x8A / 255, blue: 0x2E / 255, alpha: 1),
    ]
    let size = text.size(withAttributes: attrs)
    text.draw(
        at: NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2),
        withAttributes: attrs
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    try! render(px: px).write(to: url)
}
print("iconset: \(outDir)")
