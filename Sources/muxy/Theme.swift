import SwiftUI
import AppKit

/// UI colors. The background is parsed 1:1 from the user's ghostty theme
/// files at launch; chrome tones (sidebar, borders, active states) are
/// derived from it so the app always matches the terminal.
enum Theme {
    private static let ghostty = GhosttyColors.load()

    static let bg = dynamic(light: ghostty.light, dark: ghostty.dark)
    static let surface = dynamic(
        light: ghostty.light.shifted(by: -0.045),
        dark: ghostty.dark.shifted(by: 0.028)
    )
    static let surfaceActive = dynamic(
        light: ghostty.light.shifted(by: 0.6),
        dark: ghostty.dark.shifted(by: 0.07)
    )
    static let border = dynamic(
        light: ghostty.light.shifted(by: -0.11),
        dark: ghostty.dark.shifted(by: 0.08)
    )

    /// The terminal's own background at its configured opacity — chrome
    /// painted with it reads as part of the terminal, not a frame around it.
    static let terminal = bg.opacity(ghostty.opacity)

    /// The sidebar: a darker tone at exactly the terminal's opacity. Areas of
    /// different opacity side by side leave a visible line in Mission
    /// Control, where macOS redraws the window blur.
    static let sidebar = surface.opacity(ghostty.opacity)

    static let textPrimary = dyn(light: 0x1A1A1A, dark: 0xF0F0F0)
    static let textBody = dyn(light: 0x3A3A3A, dark: 0xC8C8C8)
    static let textMuted = dyn(light: 0x707070, dark: 0x9A9A9A)
    static let textDim = dyn(light: 0x909090, dark: 0x6A6A6A)
    static let textFaint = dyn(light: 0xA6A6A6, dark: 0x5A5A5A)
    static let accent = dyn(light: 0xE8630C, dark: 0xFF8A2E)
    static let green = dyn(light: 0x2E7D32, dark: 0x28C840)
    static let red = dyn(light: 0xB3001B, dark: 0xE63946)
    static let dotIdle = dyn(light: 0xC4C4C0, dark: 0x3A3A3A)
    static let claude = dyn(light: 0xBE5A38, dark: 0xD97757)
    static let codex = dyn(light: 0x4A55E0, dark: 0x8E9BFF)

    // Status tones: a soft tint for backgrounds, a strong shade for
    // text and icons on it.
    struct Tone {
        let soft: Color
        let strong: Color
    }

    static let blue = tone(soft: 0xEDF3FC, strong: 0x315C9B, base: 0x5080D8, darkStrong: 0x9DBAF0)
    static let greenTone = tone(soft: 0xEEF9E1, strong: 0x3F6F12, base: 0x83CD2D, darkStrong: 0xA9DE6E)
    static let yellow = tone(soft: 0xFEF7DC, strong: 0x8A6100, base: 0xF2B705, darkStrong: 0xF5CF5B)
    static let orange = tone(soft: 0xFFF3E5, strong: 0x9B5609, base: 0xF78C10, darkStrong: 0xFFB45C)
    static let redTone = tone(soft: 0xFEF2F2, strong: 0xB91C1C, base: 0xDC2626, darkStrong: 0xF87171)
    static let neutral = Tone(soft: textPrimary.opacity(0.06), strong: textMuted)

    /// Hover / selection fills — ink at low opacity works on any theme.
    static let fillHover = textPrimary.opacity(0.04)
    static let fillActive = textPrimary.opacity(0.075)
    static let hairline = textPrimary.opacity(0.09)

    /// The color an agent state speaks in.
    static func tone(for agent: AgentState) -> Tone {
        switch agent {
        case .blocked: orange
        case .failed: redTone
        case .working: blue
        case .idle: greenTone
        case .none: neutral
        }
    }

    /// The terminal's own font (Ghostty's `font-family`), for text that
    /// quotes the terminal; the system monospace when it isn't installed.
    static func mono(size: CGFloat) -> Font {
        if let family = GhosttyColors.fontFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return Font(font)
        }
        return .system(size: size, design: .monospaced)
    }

    /// Standard motion curve: fast start, long soft landing.
    static let ease = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.25)

    private static func tone(soft: Int, strong: Int, base: Int, darkStrong: Int) -> Tone {
        let baseRGB = RGB(hex: base)
        let darkSoft = NSColor(srgbRed: baseRGB.r, green: baseRGB.g, blue: baseRGB.b, alpha: 0.16)
        let softColor = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkSoft : RGB(hex: soft).nsColor
        })
        return Tone(soft: softColor, strong: dyn(light: strong, dark: darkStrong))
    }

    private static func dyn(light: Int, dark: Int) -> Color {
        dynamic(light: RGB(hex: light), dark: RGB(hex: dark))
    }

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return rgb.nsColor
        })
    }
}

struct RGB {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    init(hex: Int) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }

    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text = String(text.dropFirst()) }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// Positive amounts blend toward white, negative toward black.
    func shifted(by amount: CGFloat) -> RGB {
        var copy = self
        let target: CGFloat = amount >= 0 ? 1 : 0
        let strength = abs(amount)
        copy.r += (target - copy.r) * strength
        copy.g += (target - copy.g) * strength
        copy.b += (target - copy.b) * strength
        return copy
    }

    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// Reads `theme = light:X,dark:Y` from the user's ghostty config and pulls
/// each theme file's `background = #…`.
enum GhosttyColors {
    struct Pair {
        var light: RGB
        var dark: RGB
        var opacity: CGFloat = 1
    }

    static func load() -> Pair {
        var pair = Pair(light: RGB(hex: 0xF4F4F0), dark: RGB(hex: 0x0F0F0F))
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty")
        guard let content = try? String(
            contentsOf: config.appendingPathComponent("config"), encoding: .utf8
        ) else { return pair }
        var explicit: RGB?

        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("background-opacity"),
               let value = line.split(separator: "=", maxSplits: 1).last,
               let number = Double(value.trimmingCharacters(in: .whitespaces)).map({ CGFloat($0) }) {
                pair.opacity = min(max(number, 0), 1)
                continue
            }
            // An explicit `background = #…` beats the theme's.
            if line.hasPrefix("background"),
               line.dropFirst("background".count).first.map({ $0 == " " || $0 == "=" }) == true,
               let value = line.split(separator: "=", maxSplits: 1).last,
               let color = RGB(hexString: String(value)) {
                explicit = color
                continue
            }
            guard line.hasPrefix("theme"),
                  let value = line.split(separator: "=", maxSplits: 1).last
            else { continue }
            for part in value.split(separator: ",") {
                let piece = part.trimmingCharacters(in: .whitespaces)
                if piece.hasPrefix("light:") {
                    if let bg = background(theme: String(piece.dropFirst(6)), in: config) {
                        pair.light = bg
                    }
                } else if piece.hasPrefix("dark:") {
                    if let bg = background(theme: String(piece.dropFirst(5)), in: config) {
                        pair.dark = bg
                    }
                } else if let bg = background(theme: piece, in: config) {
                    pair.light = bg
                    pair.dark = bg
                }
            }
        }
        if let explicit {
            pair.light = explicit
            pair.dark = explicit
        }
        return pair
    }

    /// The first `font-family` of the user's ghostty config.
    static let fontFamily: String? = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("font-family"),
                  let value = line.split(separator: "=", maxSplits: 1).last
            else { continue }
            let name = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return name.isEmpty ? nil : name
        }
        return nil
    }()

    private static func background(theme name: String, in config: URL) -> RGB? {
        let file = config.appendingPathComponent("themes/\(name.trimmingCharacters(in: .whitespaces))")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("background"),
                  let value = line.split(separator: "=", maxSplits: 1).last
            else { continue }
            return RGB(hexString: String(value))
        }
        return nil
    }
}
