import Foundation

/// What a coding agent inside a session is doing, as reported by the
/// Claude Code hook (Scripts/claude-hook.sh) and the shell.
enum AgentState {
    /// No agent running in this tab.
    case none
    /// Agent is open and idle — its turn is over.
    case idle
    /// Agent is working on a prompt.
    case working
    /// Agent is blocked on you (permission prompt, question).
    case blocked
    /// The turn died on an API error (rate limit, overload, auth, …).
    case failed
}

/// Which coding agent runs in a tab.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Recognised from the shell's title, which shell integration sets to
    /// the running command line ("claude --resume", "codex").
    init?(commandLine: String) {
        let command = commandLine.lowercased().split(separator: " ").first.map(String.init) ?? ""
        guard let kind = AgentKind(rawValue: (command as NSString).lastPathComponent) else { return nil }
        self = kind
    }

    /// How an agent starts: a new conversation (with the prompt from
    /// MUXY_PROMPT, under an id muxy chose when the agent takes one).
    enum Start {
        case new(prompt: Bool, id: String?)
    }

    /// The command line that starts it, run by your shell. The prompt
    /// travels in MUXY_PROMPT: `"$MUXY_PROMPT"` reads the same in zsh, bash
    /// and fish, so no quoting of the prompt itself can go wrong.
    func command(_ start: Start, skipPermissions: Bool) -> String {
        var parts = [rawValue]
        #if DEBUG
        // MUXY_DEBUG_AGENT=/path/to/fake: try launches without a real agent.
        if let fake = ProcessInfo.processInfo.environment["MUXY_DEBUG_AGENT"] { parts = [fake] }
        #endif
        if skipPermissions {
            switch self {
            case .claude: parts.append("--dangerously-skip-permissions")
            case .codex: parts.append("--dangerously-bypass-approvals-and-sandbox")
            }
        }
        switch start {
        case let .new(prompt, id):
            if self == .claude, let id = id.flatMap(Self.safe) { parts += ["--session-id", id] }
            if prompt { parts.append("\"$MUXY_PROMPT\"") }
        }
        return parts.joined(separator: " ")
    }

    /// Ids go into a command line unquoted: only plain ones do.
    private static func safe(_ id: String) -> String? {
        id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil ? id : nil
    }
}

/// CI checks of a session's pull request, as GitHub reports them.
enum Checks: Equatable {
    case none
    case pending
    case failed
    case passed
}

/// Whether GitHub would merge the PR right now, apart from its checks.
enum Mergeability: Equatable {
    /// GitHub is still computing it — not a yes.
    case unknown
    case clean
    case conflicting
    /// Branch protection wants the head brought up to date.
    case behind
    case reviewRequired
    case changesRequested
    /// Anything else branch protection objects to (e.g. a required check
    /// that hasn't reported yet).
    case blocked
}

/// What the PR badge shows: the checks, whether someone is on them, and
/// whether the PR could actually be merged.
enum PRStatus: Equatable {
    /// No checks reported (yet).
    case none
    /// Checks are running.
    case running
    /// Checks failed and something in the session is working on it.
    case fixing
    /// Checks failed, nothing is running.
    case failed
    /// Merge conflicts with the base branch.
    case conflicts
    /// Still a draft.
    case draft
    /// Checks passed, but GitHub won't merge it yet.
    case waiting(Mergeability)
    /// Checks passed, not a draft, mergeable — ready.
    case ready
}

/// Where a session currently is, derived from its working directory.
struct RepoContext: Equatable {
    /// Main repository name — shared by all its worktrees. nil outside git.
    var repo: String?
    /// The main checkout's path (where worktrees branch from). nil outside git.
    var root: String?
    /// Last path component of the working directory's checkout (or the
    /// directory itself outside git).
    var folder: String
    var branch: String?
    var pr: Int?
    var checks: Checks = .none
    var isDraft = false
    var mergeability: Mergeability = .unknown

    /// The folder without the repo prefix the group header already shows
    /// ("myapp-login-fix" → "login-fix").
    var shortFolder: String {
        if let repo, folder.hasPrefix(repo + "-"), folder.count > repo.count + 1 {
            return String(folder.dropFirst(repo.count + 1))
        }
        return folder
    }

    static func plain(_ directory: String) -> RepoContext {
        RepoContext(repo: nil, folder: Paths.folderName(directory), branch: nil, pr: nil)
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// "/Users/x/foo" → "~/foo".
    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func folderName(_ path: String) -> String {
        path == home ? "~" : (path as NSString).lastPathComponent
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
