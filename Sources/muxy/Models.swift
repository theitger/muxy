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
