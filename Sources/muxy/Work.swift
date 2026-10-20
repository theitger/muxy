import Foundation

/// One piece of work, apart from the tabs that happen to show it: a branch
/// of a repository with its checkout, the issue it is for, its pull
/// request, the agent conversation behind it, and the evidence that it is
/// mergeable: which checks passed on which files, what quorum found and
/// fixed, what it collided with, what was pushed and landed.
///
/// Sessions come and go (closed, crashed, muxy updated); the work stays
/// on the board until its PR is merged or closed, or you drop it, and an
/// agent conversation can be picked up again where it was.
struct WorkItem: Codable, Equatable, Identifiable {
    /// "<main checkout>|<branch>": one item per branch of a repository.
    var id: String { WorkItem.key(root: root, branch: branch) }
    var root: String
    var branch: String
    var checkout: String?
    /// "owner/name", when known.
    var repo: String?
    var title: String
    var issue: Issue?
    var pr: Int?
    /// "open", "merged" or "closed", as GitHub says.
    var prState: String?
    var agent: AgentKind?
    /// The agent's conversation in `checkout`: resumable there.
    var conversation: String?
    var created: Date
    var touched: Date
    /// You put it away: off the board, kept for its evidence.
    var dropped = false
    var evidence: [Evidence] = []

    static func key(root: String, branch: String) -> String { root + "|" + branch }

    /// Still to be done: not merged, not closed, not dropped.
    var isOpen: Bool { !dropped && prState != "merged" && prState != "closed" }
}

/// One fact about the work, when it became true.
struct Evidence: Codable, Equatable {
    enum Kind: String, Codable {
        case checks, quorum, collision, pushed, landed
    }

    var kind: Kind
    var date: Date
    /// What it says, for people (and the PR comment).
    var text: String
    /// Good news, bad news, or neither.
    var ok: Bool?
    /// The files' tree or commit it is about, when there is one.
    var ref: String?
}

@MainActor
final class WorkLedger: ObservableObject {
    static let shared = WorkLedger()

    @Published private(set) var items: [String: WorkItem] = [:]
    private var timer: Timer?
    private var reconciling = false
    private var lastReconciled: Date?
    /// The facts last seen, so each is written down once.
    private var seen: Set<String> = []

    static var file: String { StateDirectory.path + "/work.json" }

    init() {
        if let data = FileManager.default.contents(atPath: Self.file),
           let saved = try? JSONDecoder().decode([WorkItem].self, from: data) {
            items = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for item in saved {
                for fact in item.evidence { seen.insert(Self.fingerprint(item.id, fact)) }
            }
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { WorkLedger.shared.observe() }
        }
        timer.tolerance = 1
        self.timer = timer
    }

    // MARK: Reading

    func item(for workspace: Workspace) -> WorkItem? {
        guard let root = workspace.context.root, let branch = workspace.context.branch else { return nil }
        return items[WorkItem.key(root: root, branch: branch)]
    }

    /// Open work no session shows right now.
    var withoutSession: [WorkItem] {
        let shown = Set(Store.shared.workspaces.compactMap { workspace -> String? in
            guard let root = workspace.context.root, let branch = workspace.context.branch else { return nil }
            return WorkItem.key(root: root, branch: branch)
        })
        return items.values.filter { $0.isOpen && !shown.contains($0.id) }.sorted { $0.touched > $1.touched }
    }

    // MARK: Changing

    /// Off the board; its evidence stays.
    func drop(_ item: WorkItem) {
        items[item.id]?.dropped = true
        save()
    }

    /// Adds or updates what is known about a branch's work.
    func upsert(root: String, branch: String, _ update: (inout WorkItem) -> Void) {
        let key = WorkItem.key(root: root, branch: branch)
        var item = items[key] ?? WorkItem(root: root, branch: branch, title: branch, created: Date(), touched: Date())
        let before = item
        update(&item)
        guard item != before || items[key] == nil else { return }
        items[key] = item
        save()
    }

    /// Writes a fact down once.
    func note(_ fact: Evidence, root: String, branch: String) {
        let key = WorkItem.key(root: root, branch: branch)
        let print = Self.fingerprint(key, fact)
        guard !seen.contains(print) else { return }
        seen.insert(print)
        upsert(root: root, branch: branch) { item in
            item.evidence.append(fact)
            item.touched = max(item.touched, fact.date)
        }
    }

    /// The collisions as the radar sees them now, in place of the ones it
    /// saw before: one that was resolved (or was only ever the base's) is
    /// gone from the evidence and the PR comment too.
    func current(_ collisions: [Evidence], root: String, branch: String) {
        upsert(root: root, branch: branch) { item in
            let before = item.evidence.filter { $0.kind == .collision }
            let now = collisions.map { fact in before.first { $0.text == fact.text && $0.ref == fact.ref } ?? fact }
            guard now != before else { return }
            item.evidence.removeAll { $0.kind == .collision }
            item.evidence.append(contentsOf: now)
            for fact in now where !before.contains(fact) { item.touched = max(item.touched, fact.date) }
        }
    }

    private static func fingerprint(_ key: String, _ fact: Evidence) -> String {
        "\(key)|\(fact.kind.rawValue)|\(fact.ref ?? "")|\(fact.text)"
    }

    // MARK: Watching

    /// Branches that are a base, not work on something.
    nonisolated static func isBase(_ branch: String) -> Bool {
        ["main", "master", "development", "develop", "dev", "trunk"].contains(branch)
    }

    /// What the sessions, checks, quorum, the radar and landing know now,
    /// written into the work they belong to.
    func observe() {
        for workspace in Store.shared.workspaces {
            let context = workspace.context
            guard context.repo != nil, let root = context.root, let branch = context.branch, !Self.isBase(branch) else { continue }
            let slug = QuorumWatch.shared.slugs[root] ?? HubModel.shared.checkouts.first { $0.value == root }?.key
            upsert(root: root, branch: branch) { item in
                item.checkout = context.checkout ?? item.checkout
                item.repo = slug ?? item.repo
                item.title = workspace.title
                item.issue = workspace.sessions.lazy.compactMap(\.issue).first?.saved ?? item.issue
                if let pr = context.pr {
                    item.pr = pr
                    item.prState = switch context.prState {
                    case .open: "open"
                    case .merged: "merged"
                    case .closed: "closed"
                    }
                }
                if let agent = workspace.sessions.first(where: { $0.kind != nil }) {
                    item.agent = agent.kind
                    item.conversation = agent.agentSessionID ?? item.conversation
                }
                // Back on the board when a session shows it again.
                if item.dropped, workspace.agent == .working { item.dropped = false }
            }
            record(workspace: workspace, root: root, branch: branch)
        }
        adoptPullRequests()
    }

    private func record(workspace: Workspace, root: String, branch: String) {
        let context = workspace.context
        if let result = Proofs.shared.result(for: context.checkout), result.verdict == .passed || result.verdict == .failed {
            let passed = result.verdict == .passed
            let names = (passed ? result.ran : result.failed).map(\.name).joined(separator: ", ")
            note(Evidence(kind: .checks, date: result.finished,
                          text: passed ? L("Checks passed: %@", names) : L("Checks failed: %@", names),
                          ok: passed, ref: String(result.tree.prefix(12))), root: root, branch: branch)
        }
        if let status = QuorumWatch.shared.status(for: workspace), !status.running, status.outcome != nil {
            note(Evidence(kind: .quorum, date: status.date, text: status.summary,
                          ok: status.succeeded ? true : (status.interrupted ? nil : false),
                          ref: status.runDirectory.map { ($0 as NSString).lastPathComponent }), root: root, branch: branch)
        }
        if Radar.shared.scanned {
            let collisions = Radar.shared.collisions(for: context.checkout).map { collision in
                let files = collision.files.prefix(3).joined(separator: ", ")
                return Evidence(kind: .collision, date: Date(),
                                text: collision.withBase
                                    ? L("Conflicts with %@ in %@", collision.baseName, files)
                                    : L("Collides with %@ in %@", Radar.shared.title(of: collision.other), files),
                                ok: false, ref: collision.files.sorted().joined(separator: ","))
            }
            current(collisions, root: root, branch: branch)
        }
        if let step = Landing.shared.step(for: workspace) {
            switch step {
            case .landed:
                note(Evidence(kind: .landed, date: Date(), text: L("Merged"), ok: true, ref: context.pr.map(String.init)),
                     root: root, branch: branch)
            case .merging, .reviewing:
                if let head = context.prHead {
                    note(Evidence(kind: .pushed, date: Date(), text: L("Pushed %@", String(head.prefix(8))), ok: nil,
                                  ref: head), root: root, branch: branch)
                }
            default:
                break
            }
        }
    }

    /// Your open PRs on this Mac without work for them yet (an agent's own
    /// worktree, a terminal outside muxy): their work, from now on.
    private func adoptPullRequests() {
        for pull in HubModel.shared.pulls {
            guard let branch = pull.branch, let root = HubModel.shared.checkout(of: pull.repo) else { continue }
            let key = WorkItem.key(root: root, branch: branch)
            if let known = items[key], known.pr == pull.number, known.prState == "open" { continue }
            upsert(root: root, branch: branch) { item in
                item.repo = pull.repo
                item.pr = pull.number
                item.prState = "open"
                if item.title == branch { item.title = pull.title }
            }
        }
        // Absence from a search is not proof of a merge (pagination,
        // permissions and temporary failures can all omit an open PR).
        guard HubModel.shared.updated != nil, !reconciling,
              lastReconciled.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        let candidates = items.values.filter { $0.isOpen && $0.prState == "open" && $0.repo != nil && $0.pr != nil }
        let keys = candidates.compactMap { item in item.repo.flatMap { repo in item.pr.map { "\(repo.lowercased())#\($0)" } } }
        guard !keys.isEmpty else { return }
        reconciling = true
        Task.detached(priority: .utility) {
            let result = ReviewHistory.load(keys: keys)
            await MainActor.run {
                self.reconciling = false
                self.lastReconciled = Date()
                for item in candidates {
                    guard let repo = item.repo, let pr = item.pr, let state = result.states["\(repo.lowercased())#\(pr)"] else { continue }
                    self.upsert(root: item.root, branch: item.branch) { current in
                        guard current.pr == pr else { return }
                        current.prState = state.rawValue.lowercased()
                        if state != .open { current.touched = Date() }
                    }
                }
            }
        }
    }

    // MARK: Picking it up again

    /// A session for the work again: its agent's conversation resumed in
    /// its checkout when there is one, else a new chat there.
    func resume(_ item: WorkItem, in window: WindowModel) {
        let directory = item.checkout.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? HubModel.worktree(of: item.branch, root: item.root)
        guard let directory else {
            window.show(L("Its checkout is gone."))
            return
        }
        let agent = item.agent ?? .claude
        if let conversation = item.conversation {
            let session = TerminalSession(
                directory: directory,
                command: Launcher.shellCommand(running: agent.command(.resume(id: conversation),
                                                                         skipPermissions: Store.shared.skipPermissions))
            )
            session.kind = agent
            session.agentSessionID = conversation
            session.agent = .idle
            session.issue = item.issue
            let workspace = Store.shared.makeWorkspace(directory: directory, in: window, session: session)
            BackgroundStart.start(session)
            window.show(L("%@ picks up where it was", agent.name))
            _ = workspace
        } else {
            var spec = SessionSpec(directory: directory, agent: agent)
            spec.issue = item.issue
            spec.background = true
            Store.shared.launch(spec, in: window)
        }
    }

    // MARK: The evidence, for the PR

    /// The evidence as Markdown: why this PR can be merged, or what stands
    /// in the way.
    nonisolated static func report(_ item: WorkItem) -> String {
        var lines = ["**muxy: evidence for this pull request**", ""]
        let latest = Dictionary(grouping: item.evidence, by: \.kind).compactMapValues { $0.max { $0.date < $1.date } }
        let formatter = ISO8601DateFormatter()
        for kind in [Evidence.Kind.checks, .quorum, .pushed, .landed] {
            guard let fact = latest[kind] else { continue }
            let mark = fact.ok == true ? "✅" : fact.ok == false ? "❌" : "•"
            let ref = fact.ref.map { " (`\($0)`)" } ?? ""
            lines.append("- \(mark) \(fact.text)\(ref) — \(formatter.string(from: fact.date))")
        }
        let collisions = item.evidence.filter { $0.kind == .collision }
        if collisions.isEmpty {
            lines.append("- ✅ " + L("No collisions with other work"))
        } else {
            for fact in collisions.suffix(3) { lines.append("- ⚠️ \(fact.text)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Saving

    private func save() {
        // Kept for a month after it ended: the evidence is history then.
        let month = Date().addingTimeInterval(-30 * 86400)
        let kept = items.values.filter { $0.isOpen || $0.touched > month }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(atPath: StateDirectory.path, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.file), options: .atomic)
    }
}
