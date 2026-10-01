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
}

/// CI checks of a session's pull request, as GitHub reports them.
enum Checks: Equatable {
    case none
    case pending
    case failed
    case passed
}

/// What the PR badge shows: the checks, plus whether someone is on it.
enum PRStatus: Equatable {
    /// No checks reported (yet).
    case none
    /// Checks are running.
    case running
    /// Checks failed and something in the session is working on it.
    case fixing
    /// Checks failed, nothing is running.
    case failed
    /// All checks passed — ready.
    case ready
}

/// Where a session currently is, derived from its working directory.
struct RepoContext: Equatable {
    /// Main repository name — shared by all its worktrees. nil outside git.
    var repo: String?
    /// Last path component of the working directory's checkout (or the
    /// directory itself outside git).
    var folder: String
    var branch: String?
    var pr: Int?
    var checks: Checks = .none

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
