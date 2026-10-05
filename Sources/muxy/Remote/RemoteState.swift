import Foundation
import GhosttyTerminal

/// What the phone sees and does — muxy's own model, read and driven
/// directly. Everything here runs on the main actor, like the model.
@MainActor
enum RemoteState {
    // MARK: - Sessions (the sidebar)

    static func sessions() -> [[String: Any]] {
        Store.shared.orderedWorkspaces.map { workspace in
            var item: [String: Any] = [
                "id": workspace.id.uuidString,
                "group": workspace.groupName,
                "title": workspace.title,
                "subtitle": workspace.subtitle,
                "directory": Paths.abbreviate(workspace.directory),
                "isGit": workspace.context.repo != nil,
                "agent": agentName(workspace.agent),
                "attention": workspace.needsAttention,
                "tabs": workspace.sessions.map { session in
                    [
                        "id": session.id.uuidString,
                        "kind": session.agent == .none ? "shell" : "claude",
                        "title": session.tabTitle,
                        "agent": agentName(session.agent),
                        "attention": session.needsAttention,
                    ] as [String: Any]
                },
            ]
            if let pr = workspace.context.pr {
                item["pr"] = ["number": pr, "status": prName(workspace.prStatus)]
            }
            return item
        }
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
        "y": (16, 0, "y", 121),
        "n": (45, 0, "n", 110),
        "q": (12, 0, "q", 113),
    ]

    @discardableResult
    static func press(_ key: String, in session: TerminalSession) -> Bool {
        guard let (code, mods, text, unshifted) = keys[key],
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
