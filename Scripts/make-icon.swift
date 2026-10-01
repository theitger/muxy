// Renders the muxy app icon on the macOS icon grid: a graphite squircle
// holding a stack of terminal windows — the front one live, with a prompt
// and a warm cursor; the ones behind it are the other sessions.
// Usage: swift Scripts/make-icon.swift <iconset-dir> [preview.png]
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Continuous-corner rounded rect (the squircle macOS uses).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    // Circular corners look pinched next to system icons; a longer, softer
    // curve approximates Apple's continuous corner.
    let p = CGMutablePath()
    let r = min(radius * 1.28, min(rect.width, rect.height) / 2)
    let k: CGFloat = 0.55 // bezier handle factor, softened
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    p.move(to: CGPoint(x: minX + r, y: minY))
    p.addLine(to: CGPoint(x: maxX - r, y: minY))
    p.addCurve(to: CGPoint(x: maxX, y: minY + r),
               control1: CGPoint(x: maxX - r * (1 - k), y: minY),
               control2: CGPoint(x: maxX, y: minY + r * (1 - k)))
    p.addLine(to: CGPoint(x: maxX, y: maxY - r))
    p.addCurve(to: CGPoint(x: maxX - r, y: maxY),
               control1: CGPoint(x: maxX, y: maxY - r * (1 - k)),
               control2: CGPoint(x: maxX - r * (1 - k), y: maxY))
    p.addLine(to: CGPoint(x: minX + r, y: maxY))
    p.addCurve(to: CGPoint(x: minX, y: maxY - r),
               control1: CGPoint(x: minX + r * (1 - k), y: maxY),
               control2: CGPoint(x: minX, y: maxY - r * (1 - k)))
    p.addLine(to: CGPoint(x: minX, y: minY + r))
    p.addCurve(to: CGPoint(x: minX + r, y: minY),
               control1: CGPoint(x: minX, y: minY + r * (1 - k)),
               control2: CGPoint(x: minX + r * (1 - k), y: minY))
    p.closeSubpath()
    return p
}

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// One terminal window card. `live` draws the prompt and cursor.
func window(_ ctx: CGContext, _ rect: CGRect, s: CGFloat, live: Bool, dim: CGFloat) {
    let radius = s * 0.045
    let path = squircle(rect, radius: radius)

    // Drop shadow under the card.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.05, color: rgb(0x000000, 0.55))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x18181B))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: near-black glass, a touch lighter at the top.
    linear(ctx, path, [rgb(0x26262B), rgb(0x141417)],
           from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY))

    // Title bar band + traffic lights.
    let bar = CGRect(x: rect.minX, y: rect.maxY - s * 0.075, width: rect.width, height: s * 0.075)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(rgb(0xFFFFFF, 0.045))
    ctx.fill(bar)
    ctx.setFillColor(rgb(0xFFFFFF, 0.07))
    ctx.fill(CGRect(x: rect.minX, y: bar.minY, width: rect.width, height: max(1, s * 0.002)))
    ctx.restoreGState()
    let dot = s * 0.021
    let lights: [Int] = live ? [0xFF5F57, 0xFEBC2E, 0x28C840] : [0x4A4A50, 0x4A4A50, 0x4A4A50]
    for (i, color) in lights.enumerated() {
        let x = rect.minX + s * 0.04 + CGFloat(i) * dot * 1.75
        ctx.setFillColor(rgb(color, live ? 1 : 0.9))
        ctx.fillEllipse(in: CGRect(x: x, y: bar.midY - dot / 2, width: dot, height: dot))
    }

    if live {
        // Prompt chevron + cursor block, set like a real shell line.
        let line = rect.maxY - s * 0.2
        let stroke = s * 0.03
        let cx = rect.minX + s * 0.07
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: cx, y: line + s * 0.05))
        chevron.addLine(to: CGPoint(x: cx + s * 0.05, y: line))
        chevron.addLine(to: CGPoint(x: cx, y: line - s * 0.05))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(rgb(0xF2F2F5))
        ctx.addPath(chevron)
        ctx.strokePath()
        ctx.restoreGState()

        // Cursor: warm orange with a soft glow.
        let cursor = CGRect(x: cx + s * 0.105, y: line - s * 0.055, width: s * 0.06, height: s * 0.11)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.05, color: rgb(0xFF8A2E, 0.85))
        let cursorPath = CGPath(roundedRect: cursor, cornerWidth: s * 0.008, cornerHeight: s * 0.008, transform: nil)
        ctx.addPath(cursorPath)
        ctx.setFillColor(rgb(0xFF8A2E))
        ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, CGPath(roundedRect: cursor, cornerWidth: s * 0.008, cornerHeight: s * 0.008, transform: nil),
               [rgb(0xFFB070), rgb(0xFF7A1A)],
               from: CGPoint(x: 0, y: cursor.maxY), to: CGPoint(x: 0, y: cursor.minY))

        // Faint output lines below.
        for (i, width) in [0.42, 0.3].enumerated() {
            let y = line - s * 0.13 - CGFloat(i) * s * 0.055
            let r = CGRect(x: cx, y: y, width: rect.width * CGFloat(width), height: s * 0.018)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.009, cornerHeight: s * 0.009, transform: nil))
            ctx.setFillColor(rgb(0xFFFFFF, 0.13 - CGFloat(i) * 0.04))
            ctx.fillPath()
        }
    }

    // Hairline edge: light on top, fading down — reads as glass.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(max(1, s * 0.003))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let edge = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.04)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(edge, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    if dim > 0 {
        ctx.addPath(path)
        ctx.setFillColor(rgb(0x0B0B0D, dim))
        ctx.fillPath()
    }
}

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS grid: 824/1024 body, centered, with a soft ground shadow.
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let bodyPath = squircle(body, radius: s * 0.14)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x1C1C20))
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite with a warm glow rising from below.
    linear(ctx, bodyPath, [rgb(0x3A3A40), rgb(0x1E1E22), rgb(0x141416)],
           from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY))
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xFF8A2E, 0.16), rgb(0xFF8A2E, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX + s * 0.06, y: body.minY + s * 0.1), startRadius: 0,
                           endCenter: CGPoint(x: body.midX + s * 0.06, y: body.minY + s * 0.1), endRadius: s * 0.55, options: [])
    ctx.restoreGState()

    // Stack: two sessions behind, the live one in front.
    let w = s * 0.56, h = s * 0.42
    let step = CGPoint(x: s * 0.05, y: s * 0.055)
    // Center the whole stack, not just the front card.
    let front = CGRect(x: body.midX - (w + 2 * step.x) / 2, y: body.midY - (h + 2 * step.y) / 2, width: w, height: h)
    window(ctx, front.offsetBy(dx: step.x * 2, dy: step.y * 2), s: s, live: false, dim: 0.55)
    window(ctx, front.offsetBy(dx: step.x, dy: step.y), s: s, live: false, dim: 0.3)
    window(ctx, front, s: s, live: true, dim: 0)

    // Top sheen on the squircle.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0.02)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()

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
if CommandLine.arguments.count > 2 {
    try! render(px: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("iconset: \(outDir)")
