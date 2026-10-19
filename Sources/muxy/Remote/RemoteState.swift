import Foundation
import GhosttyTerminal

/// What the phone sees and does — muxy's own model, read and driven
/// directly. Everything here runs on the main actor, like the model.
@MainActor
enum RemoteState {
    // MARK: - Sessions (the sidebar)

    static func sessions() -> [[String: Any]] {
        Store.shared.orderedWorkspaces.map { workspace in
            let featured = workspace.featured
            var item: [String: Any] = [
                "id": workspace.id.uuidString,
                "group": workspace.groupName,
                "title": workspace.title,
                "subtitle": workspace.subtitle,
                "directory": Paths.abbreviate(workspace.directory),
                "isGit": workspace.context.repo != nil,
                "agent": agentName(workspace.agent),
                "attention": workspace.needsAttention,
                "tabs": workspace.sessions.map(tab),
            ]
            if let kind = featured?.kind { item["agentKind"] = kind.rawValue }
            if let activity = featured?.snapshot?.activity { item["activity"] = activity }
            if let lines = featured?.snapshot?.lines, !lines.isEmpty { item["lines"] = lines }
            if let notice = featured?.notice { item["notice"] = notice }
            if let pr = workspace.context.pr {
                item["pr"] = ["number": pr, "status": prName(workspace.prStatus)]
            }
            if let branch = workspace.context.branch { item["branch"] = branch }
            if let agentTab = workspace.agentTab { item["agentTab"] = agentTab.id.uuidString }
            let next = Flow.next(for: workspace)
            item["next"] = ["kind": stepName(next), "title": next.title]
            item["stage"] = switch next.stage {
            case .working: "working"
            case .review: "review"
            case .ready: "ready"
            case .none: "none"
            }
            let checkout = workspace.context.checkout
            if Proofs.shared.isRunning(checkout) {
                item["proof"] = "running"
            } else if let verdict = Proofs.shared.result(for: checkout)?.verdict, verdict == .passed || verdict == .failed {
                item["proof"] = verdict.rawValue
            }
            let collisions = Radar.shared.collisions(for: checkout).map { $0.withBase ? $0.other : Radar.shared.title(of: $0.other) }
            if !collisions.isEmpty { item["collisions"] = collisions }
            if let review = QuorumWatch.shared.status(for: workspace) {
                item["quorum"] = ["summary": review.summary, "running": review.running, "clean": review.succeeded]
            }
            return item
        }
    }

    private static func tab(_ session: TerminalSession) -> [String: Any] {
        var tab: [String: Any] = [
            "id": session.id.uuidString,
            "kind": session.agent == .none && session.kind == nil ? "shell" : "agent",
            "title": session.tabTitle,
            "agent": agentName(session.agent),
            "attention": session.needsAttention,
        ]
        if let kind = session.kind { tab["agentKind"] = kind.rawValue }
        if let since = session.waitingSince { tab["since"] = since.timeIntervalSince1970 }
        // A question on screen comes along, to be answered from the list.
        let choices = Inbox.choices(of: session)
        if !choices.isEmpty {
            tab["choices"] = choices.map { ["number": $0.number, "label": $0.label, "selected": $0.selected] }
        }
        return tab
    }

    static func agentName(_ agent: AgentState) -> String {
        switch agent {
        case .none: "none"
        case .idle: "idle"
        case .working: "working"
        case .blocked: "blocked"
        case .failed: "failed"
        }
    }

    static func stepName(_ step: NextStep) -> String {
        switch step {
        case .wait: "wait"
        case .answer: "answer"
        case .openPR: "openPR"
        case .review: "review"
        case .fix: "fix"
        case .land: "land"
        case .reviewing: "reviewing"
        case .landing: "landing"
        case .none: "none"
        }
    }

    /// Issues assigned to you that no session works on yet, newest first,
    /// and whether this Mac has them cloned.
    static func issues() -> [[String: Any]] {
        let hub = HubModel.shared
        return hub.issues
            .filter { hub.session(for: $0) == nil }
            .sorted { ($0.created ?? .distantPast, $0.number) > ($1.created ?? .distantPast, $1.number) }
            .map { issue in
                var item: [String: Any] = [
                    "repo": issue.repo, "number": issue.number, "title": issue.title, "url": issue.url,
                    "labels": issue.labels, "local": hub.checkout(of: issue.repo) != nil,
                ]
                if let created = issue.created { item["created"] = created.timeIntervalSince1970 }
                return item
            }
    }

    static func account() -> [String: Any]? {
        let account = HubModel.shared.account
        guard let login = account.login else { return nil }
        var item: [String: Any] = ["login": login]
        if let name = account.name { item["name"] = name }
        if let avatar = account.avatar { item["avatar"] = avatar.absoluteString }
        return item
    }

    static func prName(_ status: PRStatus) -> String {
        switch status {
        case .none: "none"
        case .running: "running"
        case .fixing: "fixing"
        case .failed: "failed"
        case .conflicts: "conflicts"
        case .draft: "draft"
        case .waiting: "waiting"
        case .ready: "ready"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    static func session(_ id: String) -> TerminalSession? {
        for workspace in Store.shared.workspaces {
            if let session = workspace.sessions.first(where: { $0.id.uuidString == id }) {
                return session
            }
        }
        return nil
    }

    // MARK: - Screen

    /// The tab's active area as text (soft wraps joined, so it reflows on
    /// the phone). `history` adds the scrollback, capped to its last lines.
    static func screen(of session: TerminalSession, history: Bool) -> [String: Any]? {
        guard let surface = session.terminalView.currentSurface,
              var text = surface.readText(screen: history) else { return nil }
        if history {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 2000 { text = lines.suffix(2000).joined(separator: "\n") }
        }
        // Trailing blank rows of an idle shell are noise on a phone.
        while text.hasSuffix("\n") { text.removeLast() }
        let grid = surface.gridSize
        return ["text": text, "columns": grid.columns, "rows": grid.rows]
    }

    // MARK: - Input

    /// Typed text goes in like a paste (as Ghostty does for drops); Enter
    /// and special keys as real key events.
    static func type(_ text: String, enter: Bool, into session: TerminalSession) {
        if !text.isEmpty { session.terminalView.sendText(text) }
        if enter { press("enter", in: session) }
        markSeen(session)
    }

    /// A key the phone pressed: (macOS key code, Ghostty mods, text,
    /// unshifted codepoint). Ghostty turns it into whatever bytes the
    /// program in the terminal expects — Claude Code, for one, switches
    /// keyboard modes, so fixed escape sequences would be misread.
    static let keys: [String: (UInt32, UInt32, String?, UInt32)] = [
        "enter": (36, 0, nil, 0),
        "esc": (53, 0, nil, 0),
        "tab": (48, 0, nil, 0),
        "shift-tab": (48, 1, nil, 0),
        "up": (126, 0, nil, 0),
        "down": (125, 0, nil, 0),
        "right": (124, 0, nil, 0),
        "left": (123, 0, nil, 0),
        "backspace": (51, 0, nil, 0),
        "ctrl-c": (8, 2, nil, 99),
        "ctrl-d": (2, 2, nil, 100),
        "ctrl-r": (15, 2, nil, 114),
        "1": (18, 0, "1", 49),
        "2": (19, 0, "2", 50),
        "3": (20, 0, "3", 51),
        "4": (21, 0, "4", 52),
        "5": (23, 0, "5", 53),
        "6": (22, 0, "6", 54),
        "7": (26, 0, "7", 55),
        "8": (28, 0, "8", 56),
        "9": (25, 0, "9", 57),
        "y": (16, 0, "y", 121),
        "n": (45, 0, "n", 110),
        "q": (12, 0, "q", 113),
    ]

    /// macOS key codes of the letters (ANSI positions) — for ctrl + any letter.
    static let letterCodes: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    static func lookup(_ key: String) -> (UInt32, UInt32, String?, UInt32)? {
        if let known = keys[key] { return known }
        if key.hasPrefix("ctrl-"), key.count == 6, let letter = key.last, let code = letterCodes[letter],
           let ascii = letter.asciiValue {
            return (code, 2, nil, UInt32(ascii))
        }
        return nil
    }

    @discardableResult
    static func press(_ key: String, in session: TerminalSession) -> Bool {
        guard let (code, mods, text, unshifted) = lookup(key),
              let surface = session.terminalView.currentSurface else { return false }
        markSeen(session)
        return surface.sendKey(keycode: code, mods: mods, text: text, unshifted: unshifted)
    }

    /// Looking at a session on the phone counts as seeing it.
    static func markSeen(_ session: TerminalSession) {
        session.needsAttention = false
        Store.shared.updateBadge()
    }

    // MARK: - New session

    static func open(directory: String) -> String? {
        let path = (directory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let window = Store.shared.activeWindow ?? Store.shared.windows.first else { return nil }
        window.newWorkspace(directory: path)
        return Store.shared.workspaces.last?.id.uuidString
    }

    /// Where sessions have been — the phone offers these for a new one.
    static func recentDirectories() -> [String] {
        var seen = Set<String>()
        return Store.shared.workspaces.map { Paths.abbreviate($0.directory) }.filter { seen.insert($0).inserted }
    }
}
