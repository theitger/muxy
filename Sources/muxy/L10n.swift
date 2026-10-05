import Foundation

/// The app's language: English by default, German selectable in Settings.
/// Strings are written in English at the call site (`L("New Session")`) and
/// looked up in the German table when German is chosen.
enum Language: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"

    static let storageKey = "language"

    var id: String { rawValue }

    /// Each language names itself.
    var name: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    static var current: Language {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Language.init) ?? .english
    }

    /// Also hands the choice to AppKit, so standard menus (Edit, Window, …)
    /// follow after the next launch.
    static func select(_ language: Language) {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Localized text for an English source string; `%@`/`%d` placeholders are
/// filled from `args`.
func L(_ english: String, _ args: CVarArg...) -> String {
    let template = Language.current == .german ? (German.table[english] ?? english) : english
    return args.isEmpty ? template : String(format: template, arguments: args)
}

private enum German {
    static let table: [String: String] = [
        // Empty window
        "What are you working on?": "Woran arbeitest du?",
        "Every session is a folder with its tabs.": "Jede Session ist ein Ordner mit seinen Tabs.",
        "New Session": "Neue Session",
        "Search sessions": "Session suchen",
        "Next one waiting": "Zur nächsten, die wartet",
        "New Window": "Neues Fenster",

        // Menus
        "New Tab": "Neuer Tab",
        "Close Tab": "Tab schließen",
        "Sessions": "Sessions",
        "Search…": "Suchen…",
        "Previous Session": "Vorherige Session",
        "Next Session": "Nächste Session",
        "Next Tab": "Nächster Tab",
        "Hide Sidebar": "Seitenleiste ausblenden",
        "Show Sidebar": "Seitenleiste einblenden",

        // Header, sidebar, switcher
        "Sidebar (⌘B)": "Seitenleiste (⌘B)",
        "New Tab (⌘T)": "Neuer Tab (⌘T)",
        "%d sessions waiting": "%d Sessions warten",
        "Close": "Schließen",
        "Home": "Benutzerordner",
        "Search sessions …": "Session suchen …",
        "No session found.": "Keine Session gefunden.",
        "Nobody is waiting right now": "Gerade wartet keine Session",

        // PR checks
        "No checks": "Keine Checks",
        "Checks running": "Checks laufen",
        "Checks failed — being fixed": "Checks rot — wird gerade gefixt",
        "Checks failed": "Checks fehlgeschlagen",
        "Merge conflicts": "Merge-Konflikte",
        "Draft": "Entwurf",
        "Checks passed — branch out of date": "Checks grün — Branch nicht aktuell",
        "Checks passed — review required": "Checks grün — Review nötig",
        "Checks passed — changes requested": "Checks grün — Änderungen angefordert",
        "Checks passed — merge blocked": "Checks grün — Merge blockiert",
        "Checks passed — mergeability unknown": "Checks grün — Mergebarkeit unklar",
        "Ready to merge": "Bereit zum Mergen",

        // Dialogs
        "Close window?": "Fenster schließen?",
        "The session in it will end.": "Die Session darin wird beendet.",
        "The %d sessions in it will end.": "Die %d Sessions darin werden beendet.",
        "Close %@?": "%@ schließen?",
        "The running process in %@ will end.": "Der laufende Prozess in %@ wird beendet.",
        "All tabs in %@ will end.": "Alle Tabs in %@ werden beendet.",
        "Quit muxy?": "muxy beenden?",
        "Something is still running in one tab.": "In einem Tab läuft noch etwas.",
        "Something is still running in %d tabs.": "In %d Tabs läuft noch etwas.",
        "Quit": "Beenden",
        "The open session will end.": "Die offene Session wird beendet.",
        "All %d open sessions will end.": "Alle %d offenen Sessions werden beendet.",
        "Cancel": "Abbrechen",

        // Notifications ("<session> needs you")
        "needs you": "braucht dich",
        "is done": "ist fertig",
        "hit an error": "ist auf einen Fehler gelaufen",
        "· #%d passed": "· #%d ist grün",
        "· #%d failed": "· #%d Checks rot",

        // Settings
        "Phone": "Handy",
        "Use Muxy from your phone on the same Wi-Fi.": "Muxy vom Handy aus bedienen, im selben WLAN.",
        "Scan with the phone's camera.": "Mit der Handy-Kamera scannen.",
        "The code is the key: whoever scans it can use your terminals. Pair again to lock every phone out.": "Der Code ist der Schlüssel: Wer ihn scannt, kann deine Terminals bedienen. Neu koppeln sperrt alle Handys aus.",
        "1 phone connected": "1 Handy verbunden",
        "%d phones connected": "%d Handys verbunden",
        "Pair Again": "Neu koppeln",
        "No network connection.": "Keine Netzwerkverbindung.",
        "Language": "Sprache",
        "Some menus switch after the next launch.": "Manche Menüs wechseln erst nach einem Neustart.",
    ]
}
