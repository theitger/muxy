import AppKit
import GhosttyTerminal

/// The terminal's colors: muxy's neutral pair (the default), the same zinc
/// greys as the chrome, or yours from your Ghostty config, untouched.
/// Only colors change; font, size and everything else stay your config's.
enum TerminalColors: String, CaseIterable, Identifiable {
    case ghostty, neutral

    static let storageKey = "terminalColors"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .ghostty: L("Your Ghostty theme")
        case .neutral: L("Neutral")
        }
    }

    static var current: TerminalColors {
        UserDefaults.standard.string(forKey: storageKey).flatMap(TerminalColors.init) ?? .neutral
    }

    /// Rendered after your config file, so an empty theme leaves it alone.
    var theme: TerminalTheme {
        switch self {
        case .ghostty: TerminalTheme(light: .init(), dark: .init())
        case .neutral: TerminalTheme(light: Self.light, dark: Self.dark)
        }
    }

    // MARK: Font

    /// A font family of your choice; empty: your Ghostty config's.
    static let fontKey = "terminalFontFamily"
    /// Points; 0: your Ghostty config's.
    static let sizeKey = "terminalFontSize"

    static var fontFamily: String? {
        UserDefaults.standard.string(forKey: fontKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var fontSize: Double? {
        let size = UserDefaults.standard.double(forKey: sizeKey)
        return size > 0 ? size : nil
    }

    /// Colors and font together, as the terminals get them.
    static var currentTheme: TerminalTheme {
        let base = current.theme
        guard fontFamily != nil || fontSize != nil else { return base }
        func withFont(_ config: TerminalConfiguration) -> TerminalConfiguration {
            var result = config
            // font-family repeats as a fallback list in Ghostty: an empty
            // one first clears yours, or the choice would only be a fallback.
            if let family = fontFamily { result = result.custom("font-family", "\"\"").fontFamily(family) }
            if let size = fontSize { result = result.fontSize(Float(size)) }
            return result
        }
        return TerminalTheme(light: withFont(base.light), dark: withFont(base.dark))
    }

    /// Monospaced families installed on this Mac, for the picker.
    static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFont(name: family, size: 12)?.isFixedPitch == true
            || NSFontManager.shared.availableMembers(ofFontFamily: family)?.first.flatMap { member in
                (member.first as? String).flatMap { NSFont(name: $0, size: 12)?.isFixedPitch }
            } == true
    }.sorted()

    @MainActor
    static func apply() {
        TerminalSession.controller.setTheme(currentTheme)
        Store.shared.objectWillChange.send()
        Store.shared.windows.forEach { $0.objectWillChange.send() }
    }

    /// The terminal's background as the chrome paints it.
    static let neutralLight = RGB(hex: 0xFFFFFF)
    static let neutralDark = RGB(hex: 0x09090B)

    private static let light = TerminalConfiguration { config in
        config.withBackground("#ffffff")
        config.withForeground("#18181b")
        config.withCursorColor("#18181b")
        config.withSelectionBackground("#e4e4e7")
        config.withSelectionForeground("#09090b")
        // Readable on white: "white" text from tools that assume a dark
        // background still shows.
        let palette = ["#18181b", "#dc2626", "#16a34a", "#a16207", "#2563eb", "#9333ea", "#0e7490", "#71717a",
                       "#52525b", "#ef4444", "#22c55e", "#ca8a04", "#3b82f6", "#a855f7", "#0891b2", "#3f3f46"]
        for (index, color) in palette.enumerated() { config.withPalette(index, color: color) }
    }

    private static let dark = TerminalConfiguration { config in
        config.withBackground("#09090b")
        config.withForeground("#fafafa")
        config.withCursorColor("#fafafa")
        config.withSelectionBackground("#27272a")
        config.withSelectionForeground("#fafafa")
        let palette = ["#27272a", "#f87171", "#4ade80", "#facc15", "#60a5fa", "#c084fc", "#22d3ee", "#d4d4d8",
                       "#52525b", "#fca5a5", "#86efac", "#fde047", "#93c5fd", "#d8b4fe", "#67e8f9", "#fafafa"]
        for (index, color) in palette.enumerated() { config.withPalette(index, color: color) }
    }

    @MainActor
    static func select(_ choice: TerminalColors) {
        UserDefaults.standard.set(choice.rawValue, forKey: storageKey)
        // The strips painted in the terminal's color follow.
        apply()
    }
}
