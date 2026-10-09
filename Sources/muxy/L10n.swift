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
        "Checks failed, being fixed": "Checks rot, wird gerade gefixt",
        "Checks failed": "Checks fehlgeschlagen",
        "Merge conflicts": "Merge-Konflikte",
        "Draft": "Entwurf",
        "Checks passed, branch out of date": "Checks grün, Branch nicht aktuell",
        "Checks passed, review required": "Checks grün, Review nötig",
        "Checks passed, changes requested": "Checks grün, Änderungen angefordert",
        "Checks passed, merge blocked": "Checks grün, Merge blockiert",
        "Checks passed, mergeability unknown": "Checks grün, Mergebarkeit unklar",
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
        "Needs you": "Braucht dich",
        "What should happen?": "Was soll passieren?",
        "Task": "Aufgabe",
        "New Shell": "Neue Shell",
        "Repository": "Repository",
        "Agent": "Agent",
        "What should the agent do? Optional": "Was soll der Agent tun? Optional",
        "Other …": "Andere …",
        "Terminal only": "Nur Terminal",
        "Own worktree": "Eigener Worktree",
        "A separate checkout on a new branch, so sessions don't collide.": "Eigener Checkout auf neuem Branch, damit sich Sessions nicht in die Quere kommen.",
        "%@ starts in %@ on the new branch %@.": "%@ startet in %@ auf dem neuen Branch %@.",
        "%@ starts directly in %@.": "%@ startet direkt in %@.",
        "A terminal opens in %@ on the new branch %@.": "Ein Terminal öffnet sich in %@ auf dem neuen Branch %@.",
        "A terminal opens in %@.": "Ein Terminal öffnet sich in %@.",
        "No permission prompts.": "Ohne Rückfragen.",
        "Name: automatic": "Name: automatisch",
        "%@ starts in %@ on a new branch, named after the task.": "%@ startet in %@ auf einem neuen Branch, benannt nach der Aufgabe.",
        "A terminal opens in %@ on a new branch.": "Ein Terminal öffnet sich in %@ auf einem neuen Branch.",
        "Choose Folder…": "Ordner wählen …",
        "Worktree": "Worktree",
        "repository": "Repository",
        "Shell": "Shell",
        "New worktree": "Neuer Worktree",
        "Branch": "Branch",
        "agent": "Agent",
        "cancel": "abbrechen",
        "Creating worktree …": "Worktree wird angelegt …",
        "Start %@": "%@ starten",
        "Open": "Öffnen",
        "Name the branch or describe the task.": "Gib dem Branch einen Namen oder beschreib die Aufgabe.",
        "Not a git repository.": "Kein Git-Repository.",
        "git worktree add failed.": "git worktree add ist fehlgeschlagen.",
        "Skip permission prompts": "Ohne Berechtigungsabfragen starten",
        "New sessions start Claude with --dangerously-skip-permissions and Codex with --dangerously-bypass-approvals-and-sandbox.": "Neue Sessions starten Claude mit --dangerously-skip-permissions und Codex mit --dangerously-bypass-approvals-and-sandbox.",
        "Error": "Fehler",
        "Working": "Arbeitet",
        "Done": "Fertig",
        "Detailed": "Detailliert",
        "Simple": "Einfach",
        "Detailed Sessions": "Sessions detailliert",
        "Simple Sessions": "Sessions einfach",
        "is done": "ist fertig",
        "hit an error": "ist auf einen Fehler gelaufen",
        "· #%d passed": "· #%d ist grün",
        "· #%d failed": "· #%d Checks rot",

        // Settings
        "Keep the Mac awake": "Mac wach halten",
        "While Muxy runs, even with the lid closed. Asks for your password once.": "Solange Muxy läuft, auch zugeklappt. Fragt einmal nach deinem Passwort.",
        "Paused: battery below %d %%, the Mac may sleep.": "Pausiert: Akku unter %d %%, der Mac darf schlafen.",
        "On: the Mac won't sleep, lid closed included. Mind the heat in a bag.": "An: der Mac schläft nicht, auch zugeklappt. Vorsicht mit Wärme in der Tasche.",
        "Couldn't keep the Mac awake.": "Konnte den Mac nicht wach halten.",
        "Couldn't set up: unusual user name.": "Einrichtung fehlgeschlagen: ungewöhnlicher Benutzername.",
        "Couldn't set up: %@": "Einrichtung fehlgeschlagen: %@",
        "Phone": "Handy",
        "Use Muxy from your phone: anywhere through a relay, or on the same Wi-Fi.": "Muxy vom Handy aus bedienen: über einen Relay von überall, sonst im selben WLAN.",
        "Relay": "Relay",
        "e.g. muxy.example.com (empty: Wi-Fi only)": "z. B. muxy.example.com (leer: nur WLAN)",
        "Save": "Sichern",
        "Relay connected, reachable from anywhere.": "Relay verbunden, von überall erreichbar.",
        "Connecting to the relay …": "Verbinde mit dem Relay …",
        "Relay unreachable: %@": "Relay nicht erreichbar: %@",
        "Scan with the phone's camera.": "Mit der Handy-Kamera scannen.",
        "The code is the key: whoever scans it can use your terminals. Pair again to lock every phone out.": "Der Code ist der Schlüssel: Wer ihn scannt, kann deine Terminals bedienen. Neu koppeln sperrt alle Handys aus.",
        "1 phone connected": "1 Handy verbunden",
        "%d phones connected": "%d Handys verbunden",
        "Pair Again": "Neu koppeln",
        "No network connection.": "Keine Netzwerkverbindung.",
        "Language": "Sprache",
        "Some menus switch after the next launch.": "Manche Menüs wechseln erst nach einem Neustart.",
        "Setting up: %@": "Richte ein: %@",
        "%@ failed.": "%@ fehlgeschlagen.",
        "Setup failed, the session runs without it.": "Setup fehlgeschlagen, die Session läuft ohne.",
    ]
}
