// Renders the muxy app icon: the muxy window itself, as an icon — sidebar
// with sessions (branch tiles, a passing PR badge), the terminal beside it
// with colored git output, a prompt and the cursor.
// Every color is measured from muxy running the Ghostty theme it was
// designed with: Porsche GT3 RS Light (light) and Porsche GT3 RS (dark).
// Small sizes drop the fine detail.
// Usage: swift Scripts/make-icon.swift <out-dir> [preview-prefix]
//   writes <out-dir>/light/*.png, <out-dir>/dark/*.png (iconset names) and
//   <out-dir>/AppIcon.icon — the Icon Composer source macOS 26 uses for
//   its dark-mode icon (full-bleed art; the system adds shape and shadow).
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon"

struct Palette {
    let terminal: Int     // background
    let sidebar: Int
    let selectedRow: Int
    let tile: Int
    let ink: Int          // foreground
    let badgeBack: Int
    let badgeInk: Int
    let output: [Int]     // git log: hash, branch, tag, path
    let cursor: Int
    let edge: CGColor
    let shadow: CGFloat

    static let light = Palette(
        terminal: 0xF4F4F0, sidebar: 0xEAEAE7, selectedRow: 0xD9D9D7, tile: 0xDCDCD9, ink: 0x1A1A1A,
        badgeBack: 0xEEF9E1, badgeInk: 0x3F6F12,
        output: [0xC49800, 0x2E7D32, 0xB3001B, 0x1E4FA0], cursor: 0xC40019,
        edge: rgb(0x000000, 0.09), shadow: 0.28
    )
    static let dark = Palette(
        terminal: 0x0F0F0F, sidebar: 0x161616, selectedRow: 0x262626, tile: 0x232323, ink: 0xC8C8C8,
        badgeBack: 0x28321A, badgeInk: 0xA9DE6E,
        output: [0xF5C400, 0x5A9E50, 0xC40019, 0x3A6BC5], cursor: 0xF5C400,
        edge: rgb(0xFFFFFF, 0.14), shadow: 0.5
    )
}

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// A rounded text line `width` long at baseline-ish `y`.
func textLine(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, _ color: CGColor) {
    fill(ctx, rounded(CGRect(x: x, y: y - height / 2, width: width, height: height), height / 2), color)
}

func render(px: Int, _ p: Palette, fullBleed: Bool = false) -> Data {
    let canvas = CGFloat(px)
    let detail = px >= 128
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, Apple's corner radius, ground shadow.
    // Full-bleed: the same layout scaled to the whole canvas, square.
    let body = fullBleed
        ? CGRect(x: 0, y: 0, width: canvas, height: canvas)
        : CGRect(x: canvas * 100 / 1024, y: canvas * 100 / 1024, width: canvas * 824 / 1024, height: canvas * 824 / 1024)
    // Layout below is sized for an 824/1024 body; scale it up when bleeding.
    let s = fullBleed ? canvas * 1024 / 824 : canvas
    let bodyPath = fullBleed ? CGPath(rect: body, transform: nil) : rounded(body, s * 185 / 1024)
    ctx.saveGState()
    if !fullBleed {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, p.shadow))
    }
    fill(ctx, bodyPath, rgb(p.terminal))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // Sidebar.
    let side = CGRect(x: body.minX, y: body.minY, width: body.width * 0.4, height: body.height)
    fill(ctx, CGPath(rect: side, transform: nil), rgb(p.sidebar))

    // Traffic lights, set in from the corner like the real window.
    let light = s * 0.03
    for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(rgb(color))
        ctx.fillEllipse(in: CGRect(x: body.minX + s * 0.085 + CGFloat(i) * light * 1.6,
                                   y: body.maxY - s * 0.105, width: light, height: light))
    }

    // Sessions: a branch tile, title and branch; the first is selected and
    // has a passing PR.
    let rowCount = detail ? 4 : 2
    let rowHeight = detail ? s * 0.088 : s * 0.15
    let firstRow = body.maxY - (detail ? s * 0.2 : s * 0.26)
    for i in 0 ..< rowCount {
        let row = CGRect(x: side.minX + s * 0.03, y: firstRow - CGFloat(i) * (rowHeight + s * 0.018) - rowHeight / 2,
                         width: side.width - s * 0.06, height: rowHeight)
        if i == 0 { fill(ctx, rounded(row, s * 0.028), rgb(p.selectedRow)) }
        let t = rowHeight * 0.58
        let tile = CGRect(x: row.minX + s * 0.018, y: row.midY - t / 2, width: t, height: t)
        fill(ctx, rounded(tile, t * 0.3), rgb(p.tile))
        // branch glyph: a stem and a fork
        let g = CGMutablePath()
        g.move(to: CGPoint(x: tile.midX, y: tile.minY + t * 0.22))
        g.addLine(to: CGPoint(x: tile.midX, y: tile.midY))
        g.addLine(to: CGPoint(x: tile.minX + t * 0.3, y: tile.maxY - t * 0.24))
        g.move(to: CGPoint(x: tile.midX, y: tile.midY))
        g.addLine(to: CGPoint(x: tile.maxX - t * 0.3, y: tile.maxY - t * 0.24))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(max(1, t * 0.09))
        ctx.setStrokeColor(rgb(p.ink, 0.6))
        ctx.addPath(g)
        ctx.strokePath()
        ctx.restoreGState()
        if detail {
            let x = tile.maxX + s * 0.018
            textLine(ctx, x: x, y: row.midY + rowHeight * 0.15, width: row.width * [0.3, 0.38, 0.32, 0.36][i],
                     height: s * 0.013, rgb(p.ink, i == 0 ? 0.85 : 0.7))
            textLine(ctx, x: x, y: row.midY - rowHeight * 0.17, width: row.width * [0.42, 0.5, 0.36, 0.46][i],
                     height: s * 0.009, rgb(p.ink, 0.35))
            if i == 0 {
                let badge = CGRect(x: row.maxX - s * 0.068, y: row.midY - s * 0.017, width: s * 0.052, height: s * 0.034)
                fill(ctx, rounded(badge, s * 0.02), rgb(p.badgeBack))
                let check = CGMutablePath()
                check.move(to: CGPoint(x: badge.midX - s * 0.011, y: badge.midY))
                check.addLine(to: CGPoint(x: badge.midX - s * 0.002, y: badge.midY - s * 0.009))
                check.addLine(to: CGPoint(x: badge.midX + s * 0.013, y: badge.midY + s * 0.01))
                ctx.saveGState()
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.setLineWidth(s * 0.006)
                ctx.setStrokeColor(rgb(p.badgeInk))
                ctx.addPath(check)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }

    // Terminal: colored git log, then the prompt with its cursor.
    let x0 = side.maxX + s * 0.06
    let lineHeight = detail ? s * 0.016 : s * 0.045
    let gap = detail ? s * 0.052 : s * 0.11
    var y = body.maxY - (detail ? s * 0.205 : s * 0.24)
    let pane = body.maxX - x0
    let rows: [[(Int?, CGFloat)]] = detail
        ? [[(p.output[0], 0.13), (p.output[1], 0.34), (nil, 0.2)],
           [(nil, 0.52)],
           [(p.output[0], 0.13), (nil, 0.62)],
           [(p.output[0], 0.13), (p.output[2], 0.18), (p.output[1], 0.16), (nil, 0.12)],
           [(nil, 0.44)]]
        : [[(p.output[0], 0.25), (p.output[1], 0.45)],
           [(p.output[0], 0.25), (nil, 0.5)]]
    for row in rows {
        var x = x0
        for (color, width) in row {
            let w = pane * width
            textLine(ctx, x: x, y: y, width: w, height: lineHeight, color.map { rgb($0) } ?? rgb(p.ink, 0.75))
            x += w + lineHeight * 0.8
        }
        y -= gap
    }
    // prompt: path in blue, chevron, cursor
    let pathWidth = pane * (detail ? 0.22 : 0.3)
    textLine(ctx, x: x0, y: y, width: pathWidth, height: lineHeight, rgb(p.output[3]))
    let chevronX = x0 + pathWidth + lineHeight * 1.2
    let size = lineHeight * 0.9
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: chevronX, y: y + size))
    chevron.addLine(to: CGPoint(x: chevronX + size, y: y))
    chevron.addLine(to: CGPoint(x: chevronX, y: y - size))
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(lineHeight * 0.55)
    ctx.setStrokeColor(rgb(p.ink))
    ctx.addPath(chevron)
    ctx.strokePath()
    ctx.restoreGState()
    let cursor = CGRect(x: chevronX + size + lineHeight * 1.2, y: y - lineHeight * 1.5,
                        width: lineHeight * 1.5, height: lineHeight * 3)
    fill(ctx, rounded(cursor, lineHeight * 0.2), rgb(p.cursor))

    ctx.restoreGState()

    // Edge of the window/icon.
    if !fullBleed {
        ctx.addPath(bodyPath)
        ctx.setLineWidth(max(1, s * 0.003))
        ctx.setStrokeColor(p.edge)
        ctx.strokePath()
    }

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
for (folder, palette) in [("light", Palette.light), ("dark", Palette.dark)] {
    let dir = URL(fileURLWithPath: outDir).appendingPathComponent(folder)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, px) in variants {
        try! render(px: px, palette).write(to: dir.appendingPathComponent("\(name).png"))
    }
    if CommandLine.arguments.count > 2 {
        try! render(px: 1024, palette).write(to: URL(fileURLWithPath: CommandLine.arguments[2] + "-\(folder).png"))
    }
}
let iconDir = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icon")
let assets = iconDir.appendingPathComponent("Assets")
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

""".write(to: iconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("icons: \(outDir)/{light,dark,AppIcon.icon}")
