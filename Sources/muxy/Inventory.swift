import Foundation

/// Every worktree of your repositories, whoever made it: muxy, a Claude
/// Code subagent, quorum, or you by hand. What it holds, whether anything
/// runs in it, and whether it can go without losing work.
struct WorktreeInfo: Identifiable, Equatable {
    enum Owner: String, Equatable {
        case main, muxy, claude, quorum, other
    }

    var path: String
    var root: String
    var branch: String?
    var owner: Owner
    var lastCommit: Date?
    /// Changed or new files, not counting the recipe's disposable ones.
    var changes: Int
    /// Commits the base branch doesn't have.
    var ahead: Int
    /// The branch's newest PR.
    var pr: Int?
    var prState: Git.PullRequest.State?
    /// Compose project with running containers, when it is its own.
    var containers: String?
    var running: Int = 0
    var prunable = false
    /// muxy's ready-made worktree for the next session: kept on purpose.
    var spare = false

    var id: String { path }

    /// The merged PR's head is this worktree's HEAD (or contains it): the
    /// merge took exactly this work, not an older one on the same name.
    var mergedHere = false

    /// Nothing would be lost: no uncommitted work, nothing unmerged. When
    /// git couldn't tell (changes or ahead unknown, -1), it isn't finished.
    var isFinished: Bool {
        owner != .main && !spare && changes == 0 && (ahead == 0 || mergedHere)
    }

    var age: TimeInterval? { lastCommit.map { Date().timeIntervalSince($0) } }
}

enum Inventory {
    private static let git = WorkState.git

    /// All worktrees of `roots`. Blocking: a few git calls per worktree,
    /// one gh call and one docker call per repository.
    static func scan(roots: [String]) -> [WorktreeInfo] {
        // Per repository first (one gh and one docker call), then every
        // worktree on its own, several at once: git status dominates.
        struct Job {
            var entry: Entry
            var root: String
            var start: String
            var disposable: [String]
            var prs: [String: (number: Int, state: Git.PullRequest.State, head: String?)]
            var mainProject: String
        }
        let compose = composeProjects()
        var perRoot = [[Job]](repeating: [], count: roots.count)
        let rootLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: roots.count) { index in
            let root = roots[index]
            let recipe = WorktreeRecipe.load(root: root)
            let start = Launcher.startPoint(in: root, recipe: recipe)
            let prs = pullRequests(in: root)
            let mainProject = projectName(of: root)
            let disposable = (recipe?.disposable ?? []) + [WorktreeRecipe.portsFile]
            let made = entries(of: root).map { Job(entry: $0, root: root, start: start, disposable: disposable, prs: prs, mainProject: mainProject) }
            rootLock.withLock { perRoot[index] = made }
        }
        let jobs = perRoot.flatMap { $0 }
        var results = [WorktreeInfo?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            let info = inspect(job.entry, root: job.root, start: job.start, disposable: job.disposable,
                               prs: job.prs, mainProject: job.mainProject, compose: compose)
            lock.withLock { results[index] = info }
        }
        return results.compactMap { $0 }
    }

    private static func inspect(
        _ entry: Entry, root: String, start: String, disposable: [String],
        prs: [String: (number: Int, state: Git.PullRequest.State, head: String?)], mainProject: String, compose: [String: Int]
    ) -> WorktreeInfo {
        var info = WorktreeInfo(
            path: entry.path, root: root, branch: entry.branch, owner: owner(of: entry.path, root: root),
            changes: 0, ahead: 0, prunable: entry.prunable
        )
        guard !entry.prunable, FileManager.default.fileExists(atPath: entry.path) else {
            info.prunable = true
            return info
        }
        if let stamp = Shell.run(git, ["log", "-1", "--format=%ct"], in: entry.path).flatMap(Double.init) {
            info.lastCommit = Date(timeIntervalSince1970: stamp)
        }
        info.changes = changes(in: entry.path, disposable: disposable)
        info.ahead = Shell.run(git, ["rev-list", "--count", "\(start)..HEAD"], in: entry.path).flatMap(Int.init) ?? -1
        if let branch = entry.branch, let pr = prs[branch] {
            info.pr = pr.number
            info.prState = pr.state
            if pr.state == .merged, let head = pr.head, let mine = Shell.run(git, ["rev-parse", "HEAD"], in: entry.path) {
                info.mergedHere = mine == head
                    || Shell.execute(git, ["merge-base", "--is-ancestor", mine, head], in: entry.path).status == 0
            }
        }
        let marker = (try? String(contentsOfFile: (root as NSString).appendingPathComponent(".git/muxy-spare"), encoding: .utf8)) ?? ""
        info.spare = marker.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(entry.path)
        let project = projectName(of: entry.path)
        if info.owner == .main || project != mainProject, let running = compose[project] {
            info.containers = project
            info.running = running
        }
        return info
    }

    struct Entry {
        var path: String
        var branch: String?
        var prunable: Bool
    }

    static func entries(of root: String) -> [Entry] {
        guard let output = Shell.run(git, ["worktree", "list", "--porcelain"], in: root) else { return [] }
        var entries: [Entry] = []
        for block in output.components(separatedBy: "\n\n") {
            var entry = Entry(path: "", branch: nil, prunable: false)
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { entry.path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch refs/heads/") { entry.branch = String(line.dropFirst("branch refs/heads/".count)) }
                if line.hasPrefix("prunable") { entry.prunable = true }
            }
            if !entry.path.isEmpty { entries.append(entry) }
        }
        return entries
    }

    static func owner(of path: String, root: String) -> WorktreeInfo.Owner {
        if path == root { return .main }
        if Worktrees.isManaged(path, root: root) { return .muxy }
        if path.contains("/.claude/worktrees/") { return .claude }
        if path.hasPrefix(Quorum.cache + "/") { return .quorum }
        return .other
    }

    /// Changed files that count as work.
    static func changes(in checkout: String, disposable: [String]) -> Int {
        guard let status = Shell.run(git, ["status", "--porcelain", "-z", "--untracked-files=normal"], in: checkout) else { return -1 }
        return status.split(separator: "\0").filter { entry in
            guard entry.hasPrefix("?? ") else { return true }
            let path = String(entry.dropFirst(3))
            return !disposable.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }.count
    }

    /// Newest PR per head branch, one gh call.
    static func pullRequests(in root: String) -> [String: (number: Int, state: Git.PullRequest.State, head: String?)] {
        guard !Git.rateLimited, let gh = Shell.find("gh") else { return [:] }
        let result = Shell.execute(gh, ["pr", "list", "--state", "all", "--author", "@me", "--limit", "100",
                                        "--json", "number,headRefName,state,headRefOid"], in: root, timeout: 30)
        guard result.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]] else { return [:] }
        var found: [String: (Int, Git.PullRequest.State, String?)] = [:]
        for row in rows {
            guard let branch = row["headRefName"] as? String, let number = row["number"] as? Int, found[branch] == nil else { continue }
            let state: Git.PullRequest.State = switch row["state"] as? String {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: .open
            }
            found[branch] = (number, state, row["headRefOid"] as? String)
        }
        return found
    }

    /// Compose projects with running containers: name → count.
    static func composeProjects() -> [String: Int] {
        guard let docker = Docker.available() else { return [:] }
        let result = Shell.execute(docker, ["compose", "ls", "--format", "json"], in: Paths.home, timeout: 10)
        Docker.answered(result.status != -1)
        guard result.status == 0,
              let rows = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]] else { return [:] }
        var found: [String: Int] = [:]
        for row in rows {
            guard let name = row["Name"] as? String, let status = row["Status"] as? String,
                  let count = status.groups(#"running\((\d+)\)"#).flatMap({ Int($0[0]) }) else { continue }
            found[name] = count
        }
        return found
    }

    /// The Compose project a checkout's containers run under: its .env's
    /// COMPOSE_PROJECT_NAME, else Compose's default, the folder name.
    static func projectName(of checkout: String) -> String {
        let env = Worktrees.read((checkout as NSString).appendingPathComponent(".env"))
        if let name = env["COMPOSE_PROJECT_NAME"], !name.isEmpty { return name }
        return String((checkout as NSString).lastPathComponent.lowercased().unicodeScalars.map {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) ? Character($0) : "_"
        })
    }

    /// The project name Compose resolves for a checkout (its `name:`, the
    /// environment, .env, the folder: all of Compose's own rules). nil
    /// without Docker or a Compose file: then nothing is torn down.
    static func composeName(of checkout: String) -> String? {
        guard let docker = Docker.available() else { return nil }
        let result = Shell.execute(docker, ["compose", "config", "--format", "json"], in: checkout, timeout: 30)
        Docker.answered(result.status != -1)
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        else { return nil }
        return json["name"] as? String
    }

    /// Takes a worktree away: its own containers down (never ones it shares
    /// with the main checkout), the folder, and its branch when that is
    /// merged or holds nothing of its own. False when git refused.
    static func remove(_ info: WorktreeInfo) -> Bool {
        guard info.owner != .main else { return false }
        if info.prunable || !FileManager.default.fileExists(atPath: info.path) {
            return Shell.execute(git, ["worktree", "prune"], in: info.root).status == 0
        }
        if !info.isFinished { Checkpoints.record(.after, label: "Removed worktree", in: info.path) }
        // Containers go only when Compose itself says they are this
        // worktree's own project, never one it shares with the main checkout.
        if let mine = composeName(of: info.path), let main = composeName(of: info.root), mine != main {
            if let teardown = WorktreeRecipe.load(root: info.root)?.teardown {
                _ = Worktrees.runInLoginShell(teardown, in: info.path, timeout: 300)
            } else if info.containers != nil, let docker = Shell.find("docker") {
                _ = Shell.execute(docker, ["compose", "down", "--remove-orphans"], in: info.path, timeout: 300)
            }
        }
        guard Shell.execute(git, ["worktree", "remove", "--force", info.path], in: info.root, timeout: 120).status == 0 else {
            return false
        }
        // Removed with work in it (you confirmed): its files stay as a
        // checkpoint, so even that can be brought back.
        if info.isFinished { Checkpoints.forget(info.path, root: info.root) }
        if let branch = info.branch, info.mergedHere || info.ahead == 0 {
            _ = Shell.execute(git, ["branch", "-D", branch], in: info.root)
        }
        return true
    }
}

/// The inventory for the hub, scanned on request.
@MainActor
final class InventoryModel: ObservableObject {
    static let shared = InventoryModel()

    @Published private(set) var worktrees: [WorktreeInfo] = []
    @Published private(set) var scanning = false
    @Published private(set) var removing: Set<String> = []
    @Published private(set) var scanned: Date?

    func scan() {
        guard !scanning else { return }
        scanning = true
        let open = Store.shared.workspaces.compactMap(\.context.root)
        Task.detached(priority: .userInitiated) {
            let roots = Self.roots(open: open)
            let found = Inventory.scan(roots: roots)
            await MainActor.run {
                self.worktrees = found
                self.scanning = false
                self.scanned = Date()
            }
        }
    }

    /// Repositories with more than their main checkout, plus those with
    /// sessions.
    nonisolated static func roots(open: [String]) -> [String] {
        let all = Repos.load(open: open).map(\.path)
        return all.filter { root in open.contains(root) || Inventory.entries(of: root).count > 1 }
    }

    func hasSession(_ info: WorktreeInfo) -> Bool {
        Store.shared.workspaces.contains { $0.context.checkout == info.path }
    }

    func remove(_ list: [WorktreeInfo], then: @escaping (Int) -> Void = { _ in }) {
        let targets = list.filter { !removing.contains($0.path) && !hasSession($0) }
        targets.forEach { removing.insert($0.path) }
        Task.detached(priority: .userInitiated) {
            var removed = 0
            for info in targets where Inventory.remove(info) { removed += 1 }
            let count = removed
            await MainActor.run {
                targets.forEach { self.removing.remove($0.path) }
                self.worktrees.removeAll { info in targets.contains { $0.path == info.path } && !FileManager.default.fileExists(atPath: info.path) }
                then(count)
                self.scan()
            }
        }
    }

    /// quorum's own cleanup for its run folders.
    func quorumGC(then: @escaping () -> Void) {
        Task.detached(priority: .utility) {
            if let quorum = Shell.find("quorum") {
                _ = Shell.execute(quorum, ["gc"], in: Paths.home, timeout: 300)
            }
            await MainActor.run {
                then()
                self.scan()
            }
        }
    }
}

/// Docker when it answers. A daemon that hangs (Docker Desktop asleep or
/// stuck) costs every call its whole timeout: after one that timed out,
/// docker isn't asked again for a few minutes.
enum Docker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var quietUntil = Date.distantPast

    static func available() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard Date() >= quietUntil else { return nil }
        return Shell.find("docker")
    }

    /// `false`: it timed out.
    static func answered(_ answered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        quietUntil = answered ? .distantPast : Date().addingTimeInterval(300)
    }
}
