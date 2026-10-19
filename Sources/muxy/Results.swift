import SwiftUI

/// Where a session stands after its agent's turn, in outcomes rather than
/// code: what the agent says it did, whether tests ran and passed, how
/// much changed, and the PR with its checks.
struct SessionResult: Equatable {
    var summary: String?
    var tests: TestRun?
    var changes: DiffCount?
    var pr: PullRequestResult?
    var updated: Date
}

struct DiffCount: Equatable {
    var files: Int
    var insertions: Int
    var deletions: Int

    /// " 3 files changed, 10 insertions(+), 2 deletions(-)".
    static func parse(shortstat: String) -> DiffCount {
        func number(_ word: String) -> Int {
            shortstat.groups(#"(\d+) "# + word).flatMap { Int($0[0]) } ?? 0
        }
        return DiffCount(files: number("files? changed"), insertions: number("insertions?"), deletions: number("deletions?"))
    }
}

struct PullRequestResult: Equatable {
    var number: Int
    var state: Git.PullRequest.State
    var url: String
    var checks: Checks
    /// Names of the checks that failed, each once.
    var failing: [String]

    /// GitHub's checks page of the PR.
    var checksURL: String { url + "/checks" }
}

/// Every session's result, built when its agent ends a turn (the hook's
/// "stop") and whenever you ask. Also knows which window shows the result
/// panel.
@MainActor
final class Results: ObservableObject {
    static let shared = Results()

    @Published private(set) var bySession: [TerminalSession.ID: SessionResult] = [:]
    @Published private(set) var building: Set<TerminalSession.ID> = []
    /// Windows with the result panel open.
    @Published private(set) var panels: Set<WindowModel.ID> = []

    /// Each session's log as its hook reported it, for every agent (the
    /// remote reads `transcriptPath`, kept per session too).
    private var logs: [TerminalSession.ID: String] = [:]
    private var tokens: [TerminalSession.ID: Int] = [:]

    func noteLog(_ path: String, for session: TerminalSession) {
        logs[session.id] = path
    }

    /// The result a workspace's card speaks for: its agent tab's, else the
    /// newest of any tab.
    func result(for workspace: Workspace) -> SessionResult? {
        if let featured = workspace.featured, let result = bySession[featured.id] { return result }
        return workspace.sessions.compactMap { bySession[$0.id] }.max { $0.updated < $1.updated }
    }

    /// The tab a workspace's result is built from.
    func source(in workspace: Workspace) -> TerminalSession? {
        workspace.featured.flatMap { $0.kind != nil || bySession[$0.id] != nil ? $0 : nil }
            ?? workspace.sessions.first { $0.kind != nil }
    }

    func isPanelOpen(in window: WindowModel) -> Bool { panels.contains(window.id) }

    func togglePanel(in window: WindowModel) {
        withAnimation(Theme.ease) {
            if panels.remove(window.id) == nil {
                panels.insert(window.id)
                if let workspace = window.selectedWorkspace, let session = source(in: workspace) { refresh(session) }
            }
        }
    }

    func closePanel(in window: WindowModel) {
        _ = withAnimation(Theme.ease) { panels.remove(window.id) }
    }

    /// The agent ended a turn: its log may still be catching up, so the
    /// result is read a moment later.
    func turnEnded(in session: TerminalSession) {
        refresh(session, after: 1, turnEnded: true)
    }

    /// Builds the session's result off the main thread. Blocking work:
    /// the log's tail, one git diff, one gh call when there may be a PR.
    func refresh(_ session: TerminalSession, after delay: TimeInterval = 0, turnEnded: Bool = false) {
        let id = session.id
        let token = (tokens[id] ?? 0) + 1
        tokens[id] = token
        building.insert(id)
        let log = logs[id]
        let kind = session.kind
        let conversation = session.agentSessionID
        let context = session.context
        let directory = session.cwd
        Task.detached(priority: .utility) {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let result = Self.build(
                log: log, kind: kind, conversation: conversation, context: context, directory: directory
            )
            await MainActor.run {
                guard self.tokens[id] == token else { return }
                self.building.remove(id)
                self.bySession[id] = result
                // The turn's checkpoint carries the agent's words; then
                // muxy checks the work itself.
                if turnEnded, let checkout = context.checkout {
                    Turns.shared.turnEnded(in: checkout, summary: result.summary)
                    Proofs.shared.turnEnded(in: session)
                    Radar.shared.poke()
                }
            }
        }
    }

    nonisolated static func build(
        log: String?, kind: AgentKind?, conversation: String?, context: RepoContext, directory: String
    ) -> SessionResult {
        var result = SessionResult(updated: Date())
        let path = log ?? kind.flatMap { kind in conversation.flatMap { Transcripts.locate(agent: kind, conversation: $0) } }
        if let path, let lines = Transcripts.tail(of: path) {
            // The log says which agent wrote it; a session's kind can lag.
            let codex = path.contains("/rollout-") || kind == .codex && !path.contains("/.claude/")
            let turn = codex ? Transcripts.codexTurn(lines) : Transcripts.claudeTurn(lines)
            result.summary = turn.summary.map(PlainText.from).flatMap { $0.isEmpty ? nil : $0 }
            result.tests = turn.tests
        }
        if let checkout = context.checkout, let root = context.root {
            result.changes = diff(in: checkout, root: root)
        }
        if Git.mayHavePR(context.branch) {
            result.pr = pullRequest(in: context.checkout ?? directory)
        }
        return result
    }

    /// Files changed since the branch left its start point, uncommitted
    /// work and new files included.
    nonisolated static func diff(in checkout: String, root: String) -> DiffCount? {
        let git = "/usr/bin/git"
        let start = Launcher.startPoint(in: root, recipe: WorktreeRecipe.load(root: root))
        let base = Shell.run(git, ["merge-base", "HEAD", start], in: checkout) ?? "HEAD"
        let stat = Shell.execute(git, ["diff", "--shortstat", base], in: checkout, timeout: 20)
        guard stat.status == 0 else { return nil }
        var count = DiffCount.parse(shortstat: stat.output)
        let untracked = Shell.execute(git, ["ls-files", "--others", "--exclude-standard"], in: checkout, timeout: 20)
        if untracked.status == 0 {
            count.files += untracked.output.split(separator: "\n").count
        }
        return count
    }

    /// The branch's PR and its checks, the failing ones by name.
    nonisolated static func pullRequest(in directory: String) -> PullRequestResult? {
        guard let gh = Shell.find("gh") else { return nil }
        let result = Shell.execute(gh, ["pr", "view", "--json", "number,state,url,statusCheckRollup"], in: directory, timeout: 30)
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        else { return nil }
        return pullRequest(from: json)
    }

    nonisolated static func pullRequest(from json: [String: Any]) -> PullRequestResult? {
        guard let number = json["number"] as? Int else { return nil }
        let rollup = json["statusCheckRollup"] as? [[String: Any]] ?? []
        let failingStates: Set = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]
        var failing: [String] = []
        for check in rollup {
            let verdict = (check["conclusion"] as? String) ?? (check["state"] as? String) ?? ""
            // Check runs have a name, commit statuses a context.
            guard failingStates.contains(verdict),
                  let name = (check["name"] as? String) ?? (check["context"] as? String),
                  !failing.contains(name)
            else { continue }
            failing.append(name)
        }
        let state: Git.PullRequest.State = switch json["state"] as? String {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
        return PullRequestResult(
            number: number, state: state, url: json["url"] as? String ?? "",
            checks: Git.checks(from: rollup), failing: failing
        )
    }
}
