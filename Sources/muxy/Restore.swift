import Foundation

/// What survives a quit, a crash or an update: every window's sessions,
/// their tabs, where each one was and which agent conversation ran in it.
/// Agents come back with their conversation (`claude --resume`, `codex
/// resume`), shells in their folder.
struct SavedSessions: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var directory: String
        var agent: String?
        var conversation: String?
        var skipPermissions: Bool?
    }

    struct Workspace: Codable, Equatable {
        var tabs: [Tab]
        var selected: Int?
    }

    struct Window: Codable, Equatable {
        var workspaces: [Workspace]
        var selected: Int?
    }

    var windows: [Window]

    /// The installed app and a development build keep separate files: one
    /// must never bring back the other's sessions.
    static let file: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("muxy", isDirectory: true)
        let name = Bundle.main.bundleIdentifier == nil ? "sessions-dev.json" : "sessions.json"
        return folder.appendingPathComponent(name)
    }()

    static func load() -> SavedSessions? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SavedSessions.self, from: data)
    }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: Self.file, options: .atomic)
    }
}

extension SavedSessions.Tab {
    @MainActor
    init?(_ session: TerminalSession) {
        // A worktree still being made has no folder of its own yet.
        guard session.preparing == nil else { return nil }
        directory = session.cwd
        if session.agent != .none, let kind = session.kind {
            agent = kind.rawValue
            conversation = session.agentSessionID
            skipPermissions = session.skipsPermissions
        }
    }

    /// The tab again: its agent resumed, else a shell. nil when its folder
    /// is gone (a removed worktree): there is nothing to come back to.
    @MainActor
    func session() -> TerminalSession? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let kind = agent.flatMap(AgentKind.init(rawValue:)) else {
            return TerminalSession(directory: directory)
        }
        let skip = skipPermissions ?? false
        let session = TerminalSession(
            directory: directory,
            command: Launcher.shellCommand(running: kind.command(.resume(id: conversation), skipPermissions: skip))
        )
        session.kind = kind
        session.agent = .idle
        session.agentSessionID = conversation
        session.skipsPermissions = skip
        return session
    }
}
