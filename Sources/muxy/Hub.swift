import AppKit

/// What GitHub has for you across all repositories, through `gh` (its
/// login is muxy's login): issues assigned to you and pull requests that
/// wait for your review. Refreshed every few minutes while muxy runs.
@MainActor
final class HubModel: ObservableObject {
    static let shared = HubModel()

    struct Account: Equatable {
        var login: String?
        var name: String?
        var avatar: URL?
        var profile: URL?
        /// gh missing or signed out: what to say instead.
        var problem: String?
    }

    struct ReviewRequest: Identifiable, Equatable {
        var repo: String
        var number: Int
        var title: String
        var url: String
        var author: String
        var id: String { "\(repo)#\(number)" }
    }

    /// A pull request of yours that is still open.
    struct OwnPull: Identifiable, Equatable {
        var repo: String
        var number: Int
        var title: String
        var url: String
        var draft = false
        var updated: Date?
        /// Its branch, known for repositories cloned here; nil for a fork's.
        var branch: String?
        var id: String { "\(repo)#\(number)" }
    }

    @Published private(set) var account = Account()
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var reviews: [ReviewRequest] = []
    @Published private(set) var pulls: [OwnPull] = []
    @Published private(set) var loading = false
    @Published private(set) var updated: Date?
    /// "owner/name" → local main checkout.
    @Published private(set) var checkouts: [String: String] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 30
        self.timer = timer
        // Back from GitHub (a merge, a new PR): fresh at once, not in minutes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        }
    }

    /// Refreshes unless the last answer is under half a minute old.
    func refreshIfStale() {
        guard updated.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let open = Store.shared.workspaces.compactMap(\.context.root)
        Task.detached(priority: .utility) {
            let account = Self.loadAccount()
            let issues = account.login == nil ? [] : Self.assignedIssues()
            let reviews = account.login == nil ? [] : Self.reviewRequests()
            var map: [String: String] = [:]
            for repo in Repos.load(open: open) {
                if let slug = Issues.repo(of: repo.path), map[slug.lowercased()] == nil { map[slug.lowercased()] = repo.path }
            }
            let found = map
            let pulls = account.login == nil ? [] : Self.ownPulls(cloned: Set(found.keys))
            await MainActor.run {
                self.account = account
                if let issues { self.issues = issues }
                if let reviews { self.reviews = reviews }
                if let pulls { self.pulls = pulls }
                self.checkouts = found
                self.loading = false
                self.updated = Date()
            }
        }
    }

    /// The local main checkout of a GitHub repository, if you have one.
    func checkout(of repo: String) -> String? {
        checkouts[repo.lowercased()]
    }

    /// The session already working on an issue.
    func session(for issue: Issue) -> Workspace? {
        Store.shared.workspaces.first { workspace in
            workspace.sessions.contains { $0.issue?.number == issue.number && $0.issue?.repo.lowercased() == issue.repo.lowercased() }
                || workspace.context.branch?.hasPrefix("\(issue.number)-") == true
                    && workspace.context.root.map { checkout(of: issue.repo) == $0 } == true
        }
    }

    /// The session working on a pull request: on its branch, or showing it.
    func session(for pull: OwnPull) -> Workspace? {
        guard let root = checkout(of: pull.repo) else { return nil }
        return Store.shared.workspaces.first { workspace in
            workspace.context.root == root
                && (workspace.context.pr == pull.number || pull.branch != nil && workspace.context.branch == pull.branch)
        }
    }

    /// Your open pull requests no session works on: the work you left
    /// somewhere else (another terminal, a worktree an agent made itself).
    var pullsWithoutSession: [OwnPull] {
        pulls.filter { session(for: $0) == nil }
    }

    // MARK: gh (blocking)

    nonisolated static func loadAccount() -> Account {
        guard let gh = Shell.find("gh") else { return Account(problem: L("gh is not installed.")) }
        let result = Shell.execute(gh, ["api", "user"], in: Paths.home, timeout: 15)
        if result.status == 0,
           let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
           let login = json["login"] as? String {
            return Account(
                login: login, name: json["name"] as? String,
                avatar: (json["avatar_url"] as? String).flatMap(URL.init(string:)),
                profile: (json["html_url"] as? String).flatMap(URL.init(string:))
            )
        }
        let text = result.error.lowercased()
        if text.contains("auth login") || text.contains("not logged") || text.contains("401") {
            return Account(problem: L("gh is not signed in."))
        }
        return Account(problem: L("GitHub didn't answer."))
    }

    nonisolated static func assignedIssues() -> [Issue]? {
        guard let gh = Shell.find("gh") else { return nil }
        let result = Shell.execute(gh, [
            "search", "issues", "--assignee", "@me", "--state", "open", "--limit", "200",
            "--sort", "created", "--json", "number,title,url,labels,repository,state,createdAt"
        ], in: Paths.home, timeout: 30)
        guard result.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int, let title = row["title"] as? String,
                  let repo = (row["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
            let labels = (row["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            var issue = Issue(repo: repo, number: number, title: title, url: row["url"] as? String ?? "",
                              state: (row["state"] as? String ?? "open").uppercased(), labels: labels)
            issue.created = (row["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return issue
        }
    }

    nonisolated static func reviewRequests() -> [ReviewRequest]? {
        guard let gh = Shell.find("gh") else { return nil }
        let result = Shell.execute(gh, [
            "search", "prs", "--review-requested", "@me", "--state", "open", "--limit", "30",
            "--json", "number,title,url,repository,author"
        ], in: Paths.home, timeout: 30)
        guard result.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int, let title = row["title"] as? String,
                  let repo = (row["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
            return ReviewRequest(repo: repo, number: number, title: title, url: row["url"] as? String ?? "",
                                 author: (row["author"] as? [String: Any])?["login"] as? String ?? "")
        }
    }

    /// Your open pull requests, newest change first. Their branches come
    /// from one `gh pr list` per repository cloned here (search has none).
    nonisolated static func ownPulls(cloned: Set<String>) -> [OwnPull]? {
        guard let gh = Shell.find("gh") else { return nil }
        let result = Shell.execute(gh, [
            "search", "prs", "--author", "@me", "--state", "open", "--limit", "100",
            "--sort", "updated", "--json", "number,title,url,repository,isDraft,updatedAt"
        ], in: Paths.home, timeout: 30)
        guard result.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]] else { return nil }
        var pulls: [OwnPull] = rows.compactMap { row in
            guard let number = row["number"] as? Int, let title = row["title"] as? String,
                  let repo = (row["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
            return OwnPull(repo: repo, number: number, title: title, url: row["url"] as? String ?? "",
                           draft: row["isDraft"] as? Bool ?? false,
                           updated: (row["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
        }
        for repo in Set(pulls.map { $0.repo.lowercased() }).intersection(cloned) {
            let listed = Shell.execute(gh, [
                "pr", "list", "-R", repo, "--author", "@me", "--state", "open", "--limit", "100",
                "--json", "number,headRefName,isCrossRepository"
            ], in: Paths.home, timeout: 30)
            guard listed.status == 0,
                  let rows = try? JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [[String: Any]] else { continue }
            for row in rows where row["isCrossRepository"] as? Bool != true {
                guard let number = row["number"] as? Int, let branch = row["headRefName"] as? String,
                      let index = pulls.firstIndex(where: { $0.number == number && $0.repo.lowercased() == repo }) else { continue }
                pulls[index].branch = branch
            }
        }
        return pulls
    }

    /// Where a branch is checked out in a repository, if anywhere.
    nonisolated static func worktree(of branch: String, root: String) -> String? {
        guard let output = Shell.run("/usr/bin/git", ["worktree", "list", "--porcelain"], in: root) else { return nil }
        var path: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            if line == "branch refs/heads/\(branch)" { return path }
        }
        return nil
    }

    // MARK: Picking work up

    /// A pull request of yours becomes a session again: in the worktree
    /// that has its branch, else in a new one on it (fetched when only
    /// GitHub has it). `agent` nil opens a terminal.
    func open(_ pull: OwnPull, agent: AgentKind?, in window: WindowModel) {
        guard let root = checkout(of: pull.repo), let branch = pull.branch else {
            if let url = URL(string: pull.url) { NSWorkspace.shared.open(url) }
            return
        }
        window.showHub = false
        Task.detached(priority: .userInitiated) {
            let git = "/usr/bin/git"
            let existing = Self.worktree(of: branch, root: root)
            var problem: String?
            if existing == nil,
               Shell.execute(git, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root).status != 0,
               Shell.execute(git, ["fetch", "--quiet", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], in: root, timeout: 60).status != 0 {
                problem = L("Couldn't fetch %@ from GitHub.", branch)
            } else if existing == nil {
                // Pushes and PR lookups follow the branch on GitHub.
                _ = Shell.execute(git, ["branch", "--quiet", "--set-upstream-to=origin/\(branch)", branch], in: root)
            }
            let failed = problem
            await MainActor.run {
                if let problem = failed {
                    window.show(problem)
                    return
                }
                Store.shared.launch(
                    SessionSpec(directory: existing ?? root, agent: agent, branch: existing == nil ? branch : nil),
                    in: window
                )
            }
        }
    }

    // MARK: Starting work

    /// An issue becomes a session (or several, one per agent): its own
    /// worktree on a branch named after it, the agent asked to close it.
    /// `then` gets the new session's id (the first, with several agents).
    func start(_ issue: Issue, agents: [AgentKind], in window: WindowModel, hideHub: Bool = true, then: ((String?) -> Void)? = nil) {
        guard let root = checkout(of: issue.repo) else {
            window.show(L("%@ isn't cloned on this Mac", issue.repo))
            then?(nil)
            return
        }
        if hideHub { window.showHub = false }
        Task.detached(priority: .userInitiated) {
            // The body travels into the prompt; the search left it out.
            let full: Issue = if case let .found(found) = Issues.view(issue.number, repo: issue.repo, in: root) { found } else { issue }
            await MainActor.run {
                let before = Set(Store.shared.workspaces.map(\.id))
                FanOut.launch(issue: full, root: root, agents: agents, in: window)
                then?(Store.shared.workspaces.first { !before.contains($0.id) }?.id.uuidString)
            }
        }
    }

    /// Signs gh in, in a terminal where you can follow its steps.
    func signIn(in window: WindowModel) {
        window.showHub = false
        let workspace = Store.shared.makeWorkspace(directory: Paths.home, in: window)
        window.select(workspace)
        Store.shared.runInNewTab("gh auth login --web --git-protocol ssh", in: workspace)
        // The plain shell the session started with goes; the login stays.
        if let first = workspace.sessions.first, workspace.sessions.count > 1 {
            Store.shared.close(first, in: workspace)
        }
    }
}

/// One task to several agents at once, each in its own worktree on its
/// own branch: the variants run side by side, muxy's checks say which
/// holds, you keep one.
@MainActor
enum FanOut {
    static func launch(issue: Issue, root: String, agents: [AgentKind], in window: WindowModel) {
        let base = Issues.branchName(for: issue)
        let group = agents.count > 1 ? UUID().uuidString : nil
        for agent in agents {
            var spec = SessionSpec(
                directory: root, agent: agent,
                prompt: Issues.prompt(for: issue, localRepo: Issues.repo(of: root)),
                worktree: true, branch: agents.count > 1 ? "\(base)-\(agent.rawValue)" : base
            )
            spec.autoName = false
            spec.issue = issue
            spec.variantGroup = group
            Store.shared.launch(spec, in: window)
        }
    }

    /// `branch`: the variants' common name (each gets its agent appended);
    /// without one they are named after the task.
    static func launch(prompt: String, root: String, agents: [AgentKind], branch: String? = nil, in window: WindowModel) {
        let group = UUID().uuidString
        let slug = branch ?? BranchNamer.placeholder()
        for agent in agents {
            var spec = SessionSpec(directory: root, agent: agent, prompt: prompt, worktree: true, branch: "\(slug)-\(agent.rawValue)")
            spec.autoName = branch == nil
            spec.variantGroup = group
            Store.shared.launch(spec, in: window)
        }
    }

    /// The variants of one task, side by side.
    static func variants(of workspace: Workspace) -> [Workspace] {
        guard let group = workspace.variantGroup else { return [] }
        return Store.shared.workspaces.filter { $0.variantGroup == group }
    }

    /// Asks first: what the others hold that isn't committed is lost.
    static func confirmKeep(_ winner: Workspace) {
        let others = variants(of: winner).filter { $0.id != winner.id }
        let alert = NSAlert()
        alert.messageText = L("Keep “%@”?", winner.title)
        alert.informativeText = others.count == 1
            ? L("The other variant closes and its worktree goes. Its branch stays, and its last files are kept as a checkpoint.")
            : L("The %d other variants close and their worktrees go. Their branches stay, and their last files are kept as checkpoints.", others.count)
        alert.addButton(withTitle: L("Keep this one"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { keep(winner) }
    }

    /// Keeps `winner`; the other variants close and their worktrees go
    /// (their branches stay, in case).
    static func keep(_ winner: Workspace) {
        for other in variants(of: winner) where other.id != winner.id {
            Store.shared.discardVariant(other)
        }
        winner.sessions.forEach { $0.variantGroup = nil }
    }
}
