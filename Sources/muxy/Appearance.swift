import AppKit

/// Light or dark, for the whole app: the system's choice, or one of its
/// own. Terminals follow (your Ghostty config's light/dark theme pair), and
/// so does the chrome, whose colors come from those themes.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: L("System")
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppAppearance.init) ?? .system
    }

    @MainActor
    static func apply(_ choice: AppAppearance = current) {
        NSApplication.shared.appearance = switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
