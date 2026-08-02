import SwiftUI

enum AgentKind: String, CaseIterable, Identifiable {
    case shell
    case claude
    case codex

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .shell: Theme.textFaint
        case .claude: Theme.claude
        case .codex: Theme.codex
        }
    }

    /// Candidate executable paths, checked in order; falls back to
    /// resolving via login shell PATH.
    var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .shell: return []
        case .claude: return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex: return ["/opt/homebrew/bin/codex", "\(home)/.local/bin/codex", "/usr/local/bin/codex"]
        }
    }

    var resolvedExecutable: String {
        if self == .shell { return Self.userShell }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? rawValue
    }

    /// The command executed inside `/bin/zsh -lc` after cd'ing into the worktree.
    var launchInvocation: String {
        self == .shell ? "exec '\(Self.userShell)' -l" : "exec '\(resolvedExecutable)'"
    }

    /// The user's login shell from the passwd database — the SHELL env var
    /// is unreliable once muxy runs as a bundled app outside a terminal.
    static var userShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }
}

struct Project: Identifiable, Hashable {
    let path: String
    var id: String { path }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var name: String { (path as NSString).lastPathComponent }
}

struct Worktree: Identifiable, Hashable {
    let path: String
    let branch: String
    let projectPath: String

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isMain: Bool { path == projectPath }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum SessionStatus {
    case running
    case exited(Int32?)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
