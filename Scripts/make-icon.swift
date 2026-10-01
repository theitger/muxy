// Renders the muxy app icon: a lowercase m from three equal stems and two
// arches, one stroke weight with round ends. Light: warm ink on warm grey;
// dark: warm grey on a warm near-black. Deliberately a touch warmer than the
// Porsche GT3 RS Ghostty themes muxy was designed with. No detail beyond the
// letter, so every size is the same mark.
// Usage: swift Scripts/make-icon.swift <iconset-dir> [icon-composer-dir]
//   <iconset-dir>: the light .icns sizes (macOS before 26, alerts)
//   <icon-composer-dir>/AppIcon.icon: light + dark for macOS 26, whose dark
//   icon style otherwise tints the app icon itself
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct Look {
    let paper: Int
    let ink: Int
    static let light = Look(paper: 0xE6E1D8, ink: 0x2B2723)
    static let dark = Look(paper: 0x1C1A17, ink: 0xD8D1C3)
}

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func render(px: Int, _ look: Look = .light, fullBleed: Bool = false) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, Apple's corner radius, ground shadow.
    // Full-bleed (Icon Composer): the body is the whole canvas; macOS adds
    // shape and shadow itself.
    let body = fullBleed
        ? CGRect(x: 0, y: 0, width: s, height: s)
        : CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let bodyPath = fullBleed
        ? CGPath(rect: body, transform: nil)
        : CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    if !fullBleed {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: rgb(0x000000, 0.25))
    }
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(look.paper))
    ctx.fillPath()
    ctx.restoreGState()
    if !fullBleed {
        ctx.addPath(bodyPath)
        ctx.setLineWidth(max(1, s * 0.003))
        ctx.setStrokeColor(rgb(0x000000, 0.08))
        ctx.strokePath()
    }

    // The m, in a 100×100 box over the central 60% of the body.
    let box = body.insetBy(dx: body.width * 0.2, dy: body.height * 0.2)
    let u = box.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * u, y: box.minY + y * u) }
    let m = CGMutablePath()
    m.move(to: p(24, 30))
    m.addLine(to: p(24, 58))
    m.addArc(center: p(37, 58), radius: 13 * u, startAngle: .pi, endAngle: 0, clockwise: true)
    m.addLine(to: p(50, 30))
    m.move(to: p(50, 58))
    m.addArc(center: p(63, 58), radius: 13 * u, startAngle: .pi, endAngle: 0, clockwise: true)
    m.addLine(to: p(76, 30))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(11 * u)
    ctx.setStrokeColor(rgb(look.ink))
    ctx.addPath(m)
    ctx.strokePath()

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
    try! render(px: px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
}
if CommandLine.arguments.count > 2 {
    let icon = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("AppIcon.icon")
    let assets = icon.appendingPathComponent("Assets")
    try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try! render(px: 1024, .light, fullBleed: true).write(to: assets.appendingPathComponent("light.png"))
    try! render(px: 1024, .dark, fullBleed: true).write(to: assets.appendingPathComponent("dark.png"))
    try! """
    {
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "image-name" : "light.png",
              "image-name-specializations" : [
                { "appearance" : "dark", "value" : "dark.png" }
              ],
              "name" : "muxy"
            }
          ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "translucency" : { "enabled" : false, "value" : 0 }
        }
      ],
      "supported-platforms" : { "squares" : "shared" }
    }

    """.write(to: icon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
}
print("iconset: \(outDir)")
