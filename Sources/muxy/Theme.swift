import SwiftUI
import AppKit

/// UI colors. The terminal keeps your Ghostty theme 1:1 (its background
/// parsed from the theme files at launch); everything around it speaks one
/// neutral palette of its own, zinc greys, so the chrome stays calm under
/// any theme and color is left to mean something (waiting, running, failed).
enum Theme {
    private static let ghostty = GhosttyColors.load()

    /// The page: panels, the hub, chosen segments.
    static let bg = dyn(light: 0xFFFFFF, dark: 0x09090B)
    /// Floating panels and popovers.
    static let surface = dyn(light: 0xFFFFFF, dark: 0x18181B)
    /// Cards in the sidebar.
    static let surfaceActive = dyn(light: 0xFFFFFF, dark: 0x1F1F23)
    static let border = dyn(light: 0xE4E4E7, dark: 0x27272A)

    /// The terminal's own background at its configured opacity: the strip
    /// above a terminal is painted with it, so the two read as one.
    static let terminal = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rgb = TerminalColors.current == .neutral
            ? (dark ? TerminalColors.neutralDark : TerminalColors.neutralLight)
            : (dark ? ghostty.dark : ghostty.light)
        return rgb.nsColor.withAlphaComponent(TerminalColors.current == .neutral ? 1 : ghostty.opacity)
    })

    /// The sidebar and title bar, at exactly the terminal's opacity. Areas
    /// of different opacity side by side leave a visible line in Mission
    /// Control, where macOS redraws the window blur.
    static let sidebar = dyn(light: 0xFAFAFA, dark: 0x111113).opacity(ghostty.opacity)

    static let textPrimary = dyn(light: 0x09090B, dark: 0xFAFAFA)
    static let textBody = dyn(light: 0x3F3F46, dark: 0xD4D4D8)
    static let textMuted = dyn(light: 0x71717A, dark: 0xA1A1AA)
    static let textDim = dyn(light: 0x71717A, dark: 0xA1A1AA)
    static let textFaint = dyn(light: 0xB0B0B7, dark: 0x55555C)
    static let accent = dyn(light: 0xE8630C, dark: 0xFF8A2E)
    static let green = dyn(light: 0x2E7D32, dark: 0x28C840)
    static let red = dyn(light: 0xB3001B, dark: 0xE63946)
    static let dotIdle = dyn(light: 0xC4C4C0, dark: 0x3A3A3A)
    static let claude = dyn(light: 0xBE5A38, dark: 0xD97757)
    static let codex = dyn(light: 0x0D0D0D, dark: 0xF5F5F5)

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
    static let purple = tone(soft: 0xF4EEFD, strong: 0x6B3FB8, base: 0x8957E5, darkStrong: 0xC2A5F5)
    static let neutral = Tone(soft: textPrimary.opacity(0.06), strong: textMuted)

    /// Hover and selection: the palette's muted greys.
    static let fillHover = dyn(light: 0xF4F4F5, dark: 0x27272A)
    static let fillActive = dyn(light: 0xE9E9EC, dark: 0x303036)
    static let hairline = border

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
        if let family = TerminalColors.fontFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return Font(font)
        }
        if hasTerminalFont, let family = GhosttyColors.fontFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return Font(font)
        }
        return .system(size: size, design: .monospaced)
    }

    /// Your Ghostty font is installed: it has the prompt's icons (Nerd Font
    /// glyphs and the like).
    static let hasTerminalFont: Bool = GhosttyColors.fontFamily.map {
        NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 12) != nil
    } ?? false

    /// A screen line for the cards: without your font, icons from the
    /// private use area would show as boxes, so they go.
    static func displayable(_ line: String) -> String {
        guard !hasTerminalFont else { return line }
        return String(String.UnicodeScalarView(line.unicodeScalars.filter { scalar in
            !(0xE000 ... 0xF8FF).contains(scalar.value) && scalar.value < 0xF0000
        }))
    }

    /// Small labels, counts and states: the system face with digits that
    /// line up.
    static func label(size: CGFloat = 11, weight: NSFont.Weight = .medium) -> Font {
        .system(size: size, weight: Font.Weight(weight)).monospacedDigit()
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

extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case ..<NSFont.Weight.regular: self = .light
        case ..<NSFont.Weight.medium: self = .regular
        case ..<NSFont.Weight.semibold: self = .medium
        case ..<NSFont.Weight.bold: self = .semibold
        default: self = .bold
        }
    }
}
