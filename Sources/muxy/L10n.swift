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
        "They come back when muxy opens again.": "Sie kommen zurück, sobald muxy wieder öffnet.",
        "Restore sessions": "Sessions wiederherstellen",
        "After a quit, a crash or an update, every session comes back: agents with their conversation, shells in their folder.": "Nach Beenden, Absturz oder Update kommt jede Session zurück: Agents mit ihrer Unterhaltung, Shells in ihrem Ordner.",
        "Merged": "Gemergt",
        "Closed without merging": "Geschlossen, nicht gemergt",
        "Setting up: %@": "Richte ein: %@",
        "%@ failed.": "%@ fehlgeschlagen.",
        "Setup failed, the session runs without it.": "Setup fehlgeschlagen, die Session läuft ohne.",
        "#%d merged: session closed, worktree removed": "#%d gemergt: Session geschlossen, Worktree entfernt",

        // Setup and agent hooks
        "Welcome to muxy": "Willkommen bei muxy",
        "Set up muxy": "muxy einrichten",
        "Set Up muxy Again…": "muxy neu einrichten …",
        "Step %d of %d": "Schritt %d von %d",
        "Skip setup": "Einrichtung überspringen",
        "Back": "Zurück",
        "Continue": "Weiter",
        "Where do your repositories live?": "Wo liegen deine Repositorys?",
        "New sessions offer the repositories in these folders.": "Neue Sessions bieten die Repositorys aus diesen Ordnern an.",
        "No repositories found in your home folder. Add the folder you keep them in.": "In deinem Benutzerordner wurden keine Repositorys gefunden. Füg den Ordner hinzu, in dem sie liegen.",
        "1 repository": "1 Repository",
        "%d repositories": "%d Repositorys",
        "Add Folder…": "Ordner hinzufügen …",
        "Which agents do you use?": "Welche Agents nutzt du?",
        "muxy starts them for you. Choose the one ⌘N picks first.": "muxy startet sie für dich. Wähl den, den ⌘N zuerst nimmt.",
        "Not installed on this Mac": "Auf diesem Mac nicht installiert",
        "Default": "Standard",
        "Makes it the default agent": "Macht ihn zum Standard-Agent",
        "Neither Claude Code nor Codex was found. Install one, then come back here from Settings.": "Weder Claude Code noch Codex gefunden. Installier einen davon und komm dann über die Einstellungen hierher zurück.",
        "Let muxy see what your agents do": "Lass muxy sehen, was deine Agents tun",
        "A small hook tells muxy when an agent is working, done or waiting for you.": "Ein kleiner Hook sagt muxy, wann ein Agent arbeitet, fertig ist oder auf dich wartet.",
        "Installing writes:": "Die Installation schreibt:",
        "the hook script, shared by both agents": "das Hook-Skript, für beide Agents",
        "%d entries for %@. Everything else in it stays as it is.": "%d Einträge für %@. Alles andere darin bleibt, wie es ist.",
        "Outside muxy the hook does nothing. muxy keeps it up to date after updates.": "Außerhalb von muxy tut der Hook nichts. muxy hält ihn nach Updates aktuell.",
        "Install hooks": "Hooks installieren",
        "No agent found, nothing to install yet.": "Kein Agent gefunden, noch nichts zu installieren.",
        "Agent hooks": "Agent-Hooks",
        "How muxy knows an agent is working, done or needs you.": "Woher muxy weiß, ob ein Agent arbeitet, fertig ist oder dich braucht.",
        "Hooks installed": "Hooks installiert",
        "Hooks not installed": "Hooks nicht installiert",
        "Hooks outdated": "Hooks veraltet",
        "Install": "Installieren",
        "Update": "Aktualisieren",
        "%@ isn't valid JSON, muxy leaves it alone.": "%@ ist kein gültiges JSON, muxy lässt die Datei in Ruhe.",
        "Codex runs new hooks only once you trust them: type /hooks in Codex and trust muxy's.": "Codex führt neue Hooks erst aus, wenn du ihnen vertraust: tipp /hooks in Codex und vertrau denen von muxy.",
        "Hooks are switched off in Codex: remove hooks = false under [features] in its config.toml.": "Hooks sind in Codex abgeschaltet: entfern hooks = false unter [features] in der config.toml.",
        "Hear when a session needs you": "Erfahr, wann eine Session dich braucht",
        "A banner when an agent is done or waiting, while you're in another app.": "Ein Banner, wenn ein Agent fertig ist oder wartet, während du in einer anderen App bist.",
        "Allow Notifications": "Mitteilungen erlauben",
        "Notifications are on.": "Mitteilungen sind an.",
        "Notifications are off for muxy.": "Mitteilungen sind für muxy aus.",
        "Open System Settings": "Systemeinstellungen öffnen",
        "Only Muxy.app can show notifications, this build can't.": "Nur Muxy.app kann Mitteilungen zeigen, dieser Build nicht.",
        "Keep agents working while you're away": "Lass Agents weiterarbeiten, während du weg bist",
        "Optional. You can change all of this later in Settings.": "Optional. Du kannst das alles später in den Einstellungen ändern.",
        "Below %d %% battery the Mac may sleep again.": "Unter %d %% Akku darf der Mac wieder schlafen.",
        // Updates
        "Check for Updates…": "Nach Updates suchen …",
        "Check for updates automatically": "Automatisch nach Updates suchen",
        "Once a day. Muxy %@ asks before it installs anything.": "Einmal am Tag. Muxy %@ fragt, bevor es etwas installiert.",

        // Command line tool
        "Command line tool": "Kommandozeilen-Tool",
        "The muxy command in any terminal: start sessions, report into them, list them. For scripts and agents.": "Der Befehl muxy in jedem Terminal: Sessions starten, in sie melden, sie auflisten. Für Skripte und Agents.",
        "Installed as %@.": "Installiert als %@.",
        "%@ exists and is not a link. Remove it to install.": "%@ existiert und ist kein Link. Entferne die Datei, um zu installieren.",
        "Your shell doesn't look in %@. Add it to your PATH, or link the tool into a folder it does look in:": "Deine Shell sucht nicht in %@. Nimm den Ordner in deinen PATH auf oder verlinke das Tool in einen Ordner, in dem sie sucht:",
        "%@ points to %@. Install replaces the link.": "%@ zeigt auf %@. Installieren ersetzt den Link.",
        "This build doesn't include the tool.": "Dieser Build enthält das Tool nicht.",
        "Couldn't install: %@": "Installation fehlgeschlagen: %@",
        // Terminal search
        "Find in terminal": "Im Terminal suchen",
        "No matches": "Keine Treffer",
        "Matches: %@": "Treffer: %@",
        "Next Match (⌘G)": "Nächster Treffer (⌘G)",
        "Next Match": "Nächster Treffer",
        "Previous Match (⇧⌘G)": "Vorheriger Treffer (⇧⌘G)",
        "Previous Match": "Vorheriger Treffer",
        "Close (esc)": "Schließen (esc)",
        "Close Search": "Suche schließen",
        "Find in Terminal…": "Im Terminal suchen…",
        // Issues
        "What should the agent do? Or #123 for an issue": "Was soll der Agent tun? Oder #123 für ein Issue",
        "%@ works on #%d in %@ on the new branch %@.": "%@ arbeitet an #%d in %@ auf dem neuen Branch %@.",
        "%@ works on #%d directly in %@.": "%@ arbeitet an #%d direkt in %@.",
        "Looking up #%d …": "Suche #%d …",
        "Still open": "Noch offen",
        "Already closed": "Schon geschlossen",
        "Assigned to you": "Dir zugewiesen",
        "Open issues": "Offene Issues",
        "Issue %@": "Issue %@",
        "This issue is from %@, the agent starts in %@.": "Dieses Issue ist aus %@, der Agent startet in %@.",
        "#%d: choose a repository on GitHub first.": "#%d: wähl zuerst ein Repository auf GitHub.",
        "No issue #%d in %@.": "Kein Issue #%d in %@.",
        "#%d is a pull request, not an issue.": "#%d ist ein Pull Request, kein Issue.",
        "gh is not installed.": "gh ist nicht installiert.",
        "gh is not signed in.": "gh ist nicht angemeldet.",
        "gh gave an answer muxy can't read.": "gh hat etwas geantwortet, das muxy nicht lesen kann.",
        "GitHub doesn't know this repository.": "GitHub kennt dieses Repository nicht.",
        "GitHub didn't answer.": "GitHub hat nicht geantwortet.",

        // Results
        "Result": "Ergebnis",
        "Result (⌘I)": "Ergebnis (⌘I)",
        "Show result": "Ergebnis zeigen",
        "Hide result": "Ergebnis ausblenden",
        "Close result": "Ergebnis schließen",
        "Close result (⌘I)": "Ergebnis schließen (⌘I)",
        "Refresh result": "Ergebnis aktualisieren",
        "What the agent did": "Was der Agent gemacht hat",
        "The agent left no summary in this turn.": "Der Agent hat in dieser Runde keine Zusammenfassung hinterlassen.",
        "No summary": "Keine Zusammenfassung",
        "Reading the agent's log …": "Lese das Protokoll des Agents …",
        "No agent runs in this session.": "In dieser Session läuft kein Agent.",
        "No result yet. It appears when the agent finishes a turn.": "Noch kein Ergebnis. Es erscheint, sobald der Agent eine Runde beendet.",
        "Tests passed": "Tests bestanden",
        "Tests failed": "Tests fehlgeschlagen",
        "Tests ran, outcome unclear": "Tests liefen, Ergebnis unklar",
        "No tests ran in this turn": "In dieser Runde liefen keine Tests",
        "No files changed": "Keine Dateien geändert",
        "1 file changed": "1 Datei geändert",
        "%d files changed": "%d Dateien geändert",
        "No pull request yet": "Noch kein Pull Request",
        "Pull request #%d is open": "Pull Request #%d ist offen",
        "Pull request #%d is merged": "Pull Request #%d ist gemergt",
        "Pull request #%d is closed": "Pull Request #%d ist geschlossen",
        "CI passed": "CI grün",
        "CI failed": "CI rot",
        "CI running": "CI läuft",
        "No CI checks": "Keine CI-Checks",
        "Open PR": "PR öffnen",
        "Open checks": "Checks öffnen",
        "Updated %@": "Aktualisiert %@",
    ]
}
