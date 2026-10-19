import Foundation

/// What quorum (github.com/yungweng/quorum, a panel of Codex reviewers
/// that reviews, fixes and waits for CI) is doing for a pull request, read
/// from the files it keeps anyway: a run's `progress.json` / `target.json`
/// and `output/findings.json` under ~/.cache/quorum, its `run.pid`, and the
/// finished runs in ~/.local/state/quorum/history.jsonl. muxy only reads.
struct QuorumStatus: Equatable {
    enum Kind: String { case review, babysit }

    var kind: Kind
    /// "owner/name#123".
    var key: String
    var running: Bool
    /// review, fix, ci, … as quorum names it (running babysits).
    var phase: String?
    var round: Int?
    /// The run's limit on review-fix rounds (MAX_ITER when it started).
    var maxRounds: Int?
    var blockers = 0
    var critical = 0
    var suggestions = 0
    /// Finished: converged, failed, … as quorum says it.
    var outcome: String?
    var reason: String?
    var date: Date
    var runDirectory: String?
    /// The review's report, when it wrote one.
    var report: String?
    /// The pull request's title, when quorum noted it.
    var title: String?

    var repo: String { String(key.split(separator: "#").first ?? "") }
    var number: Int? { key.split(separator: "#").last.flatMap { Int($0) } }
    var url: URL? { number.flatMap { URL(string: "https://github.com/\(repo)/pull/\($0)") } }

    /// Finished and quorum says it worked. A run that failed or was
    /// cancelled is never this, whatever its counts.
    var converged: Bool {
        !running && ["converged", "ok", "clean", "merged", "success"].contains(outcome ?? "")
    }

    /// A babysit that converged fixed what it found: its counts are those
    /// findings (quorum's own HISTORY shows them so), none of them open.
    private var countsAreFixed: Bool { kind == .babysit && converged }

    /// Blockers and critical findings still open.
    var open: Int { countsAreFixed ? 0 : blockers + critical }
    /// Blockers and critical findings a converged babysit fixed.
    var fixed: Int { countsAreFixed ? blockers + critical : 0 }

    var isClean: Bool { open == 0 }

    /// Converged with nothing open.
    var succeeded: Bool { converged && isClean }

    /// One line for a card, in quorum's own terms: what it does right now,
    /// or how it ended and why.
    var summary: String {
        if running {
            guard kind == .babysit else { return L("quorum reviews") }
            var parts: [String] = []
            if let round { parts.append(maxRounds.map { L("round %d of %d", round, $0) } ?? L("round %d", round)) }
            if let doing = Self.doing(phase) { parts.append(doing) }
            return parts.isEmpty ? L("quorum works") : "quorum: " + parts.joined(separator: " · ")
        }
        switch outcome {
        case "merged":
            return L("quorum: merged")
        case "converged", "clean", "ok", "success":
            if open > 0 { return open == 1 ? L("quorum: 1 finding open") : L("quorum: %d findings open", open) }
            return fixed > 0 ? L("quorum: clean, %d fixed", fixed) : L("quorum: clean")
        case nil:
            let findings = blockers + critical
            return findings == 0 ? L("quorum: no blockers") : L("quorum: %d blockers", findings)
        default:
            return L("quorum stopped: %@", Self.why(reason))
        }
    }

    /// progress.json's phase as words.
    static func doing(_ phase: String?) -> String? {
        switch phase {
        case "review": L("reviews")
        case "fix": L("fixes")
        case "ci": L("waits for CI")
        case "ci_fix": L("fixes CI")
        case "description": L("writes the description")
        case let other?: other
        case nil: nil
        }
    }

    /// quorum's failure reason (history.jsonl) in a few words.
    static func why(_ reason: String?) -> String {
        guard let reason = reason?.lowercased(), !reason.isEmpty else { return L("failed") }
        if reason.contains("did not converge") || reason.contains("not converged") {
            let rounds = reason.split(separator: " ").compactMap { Int($0) }.first
            return rounds.map { L("not clean after %d rounds", $0) } ?? L("not clean after its rounds")
        }
        if reason.contains("test command still fails") { return L("tests still fail") }
        if reason.contains("ci") && reason.contains("red") { return L("CI still red") }
        if reason.contains("no progress") || reason.contains("produced no changes") { return L("a fix changed nothing") }
        if reason.contains("merge conflicts") { return L("conflicts with the base remain") }
        if reason.contains("context canceled") || reason.contains("cancel") { return L("cancelled") }
        if reason.contains("usage limit") { return L("usage limit reached") }
        if reason.contains("draft") { return L("the PR is a draft") }
        if reason.contains("dirty") || reason.contains("origin does not have") { return L("the branch had unpushed work") }
        if reason.contains("fix session failed") { return L("a fix session failed") }
        return L("failed")
    }
}

/// What quorum will do, from its config file with quorum's own defaults
/// (docs/reference.md): muxy shows and plans by it.
struct QuorumBehavior: Equatable {
    /// RESOLVE_CONFLICTS: babysit brings the branch up to date with its
    /// base and resolves conflicts itself.
    var resolvesConflicts = true
    /// BABYSIT_DRAFTS: drafts without `--draft`.
    var babysitsDrafts = false
    /// AUTO_MERGE: after a clean run quorum merges (not with POST=0).
    var merges = false
    /// POST: findings and the fix log go on the PR.
    var posts = true
    /// MAX_ITER: review-fix rounds before it gives up.
    var maxRounds = 12

    init() {}

    init(_ values: [String: String]) {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            guard let value = values[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }
            return value != "0"
        }
        resolvesConflicts = flag("RESOLVE_CONFLICTS", true)
        babysitsDrafts = flag("BABYSIT_DRAFTS", false)
        posts = flag("POST", true)
        merges = flag("AUTO_MERGE", false) && posts
        maxRounds = values["MAX_ITER"].flatMap { Int($0) } ?? 12
    }

    /// Read again whenever asked: the file is small and you may have just
    /// changed it (in muxy or with `quorum config`).
    static var current: QuorumBehavior { QuorumBehavior(QuorumConfig.read()) }
}

enum Quorum {
    static let cache = Paths.home + "/.cache/quorum"
    static let history = Paths.home + "/.local/state/quorum/history.jsonl"

    static var isInstalled: Bool { Shell.find("quorum") != nil }

    /// The newest status per PR, running runs first. Blocking (file reads).
    static func statuses(now: Date = Date()) -> [String: QuorumStatus] {
        var best: [String: QuorumStatus] = [:]
        func offer(_ status: QuorumStatus) {
            if let current = best[status.key] {
                if current.running && !status.running { return }
                if current.running == status.running, current.date >= status.date { return }
            }
            best[status.key] = status
        }
        for entry in finished() { offer(entry) }
        for kind in [QuorumStatus.Kind.babysit, .review] {
            let folder = cache + "/" + (kind == .babysit ? "babysit" : "reviews")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names {
                let dir = folder + "/" + name
                // Old runs left behind by failures: only the recent ones matter.
                guard let modified = modified(dir), now.timeIntervalSince(modified) < 3 * 86400,
                      let status = run(in: dir, kind: kind, modified: modified) else { continue }
                offer(status)
            }
        }
        return best
    }

    /// A run folder, alive or not.
    static func run(in dir: String, kind: QuorumStatus.Kind, modified: Date) -> QuorumStatus? {
        let alive = pid(in: dir).map { kill($0, 0) == 0 } ?? false
        var status: QuorumStatus?
        if let progress = json(dir + "/progress.json"), let repo = progress["repo"] as? String,
           let number = progress["number"] as? Int {
            status = QuorumStatus(
                kind: kind, key: "\(repo)#\(number)", running: alive,
                phase: progress["phase"] as? String, round: progress["round"] as? Int,
                maxRounds: progress["max_iter"] as? Int,
                blockers: progress["blockers"] as? Int ?? 0, critical: progress["critical"] as? Int ?? 0,
                date: date(progress["updated_at"]) ?? modified, runDirectory: dir,
                title: progress["title"] as? String
            )
        } else if let target = json(dir + "/target.json"), let repo = target["repo"] as? String,
                  let number = target["number"] as? Int {
            status = QuorumStatus(kind: kind, key: "\(repo)#\(number)", running: alive, date: modified, runDirectory: dir,
                                  title: (target["pr"] as? [String: Any])?["title"] as? String)
        }
        guard var found = status else { return nil }
        if let findings = json(dir + "/output/findings.json") {
            found.blockers = findings["blockers"] as? Int ?? found.blockers
            found.critical = findings["critical"] as? Int ?? found.critical
            found.suggestions = findings["suggestions"] as? Int ?? 0
            found.report = findings["comment_file"] as? String
        }
        // Without a process and without findings it died early: history says how.
        if !found.running, json(dir + "/output/findings.json") == nil, json(dir + "/progress.json") == nil { return nil }
        return found
    }

    /// The last 400 finished runs from quorum's history.
    static func finished() -> [QuorumStatus] {
        guard let handle = FileHandle(forReadingAtPath: history) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let lines = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").suffix(400)
        return lines.compactMap { line in
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let key = entry["key"] as? String else { return nil }
            return QuorumStatus(
                kind: QuorumStatus.Kind(rawValue: entry["kind"] as? String ?? "") ?? .review,
                key: key, running: false,
                blockers: entry["blockers"] as? Int ?? 0, critical: entry["critical"] as? Int ?? 0,
                suggestions: entry["suggestions"] as? Int ?? 0,
                outcome: entry["outcome"] as? String, reason: entry["reason"] as? String,
                date: date(entry["ended_at"]) ?? .distantPast, runDirectory: entry["run_dir"] as? String,
                title: entry["title"] as? String
            )
        }
    }

    /// The shell line that hands a PR to quorum. `draft`: a babysit on a
    /// draft PR, which quorum refuses without `--draft` unless the config
    /// allows drafts; your click is that go-ahead.
    static func command(_ kind: QuorumStatus.Kind, pr: Int, draft: Bool = false,
                        behavior: QuorumBehavior = .current) -> String {
        let flag = kind == .babysit && draft && !behavior.babysitsDrafts ? " --draft" : ""
        return "quorum \(kind.rawValue)\(flag) \(pr)"
    }

    private static func pid(in dir: String) -> pid_t? {
        (try? String(contentsOfFile: dir + "/run.pid", encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// quorum's statuses for the views, re-read every few seconds while
/// quorum has a cache at all, and each session's PR matched to them.
@MainActor
final class QuorumWatch: ObservableObject {
    static let shared = QuorumWatch()

    @Published private(set) var byKey: [String: QuorumStatus] = [:]
    /// "owner/name" of each repository root, learned off the main thread.
    @Published private(set) var slugs: [String: String] = [:]
    private var timer: Timer?

    /// `always`: also before quorum ever ran (its cache appears with the
    /// first run muxy starts).
    func start(always: Bool = false) {
        guard timer == nil, always || FileManager.default.fileExists(atPath: Quorum.cache) else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 2
        self.timer = timer
    }

    func status(for workspace: Workspace) -> QuorumStatus? {
        guard let pr = workspace.context.pr, let root = workspace.context.root, let slug = slugs[root] else { return nil }
        return byKey["\(slug)#\(pr)"]
    }

    func refresh() {
        let roots = Set(Store.shared.workspaces.compactMap(\.context.root)).subtracting(slugs.keys)
        Task.detached(priority: .utility) {
            let statuses = Quorum.statuses()
            var found: [String: String] = [:]
            for root in roots { if let slug = Issues.repo(of: root) { found[root] = slug } }
            let learned = found
            await MainActor.run {
                let before = self.byKey
                self.slugs.merge(learned) { _, new in new }
                if statuses != before { self.byKey = statuses }
                self.announce(before: before, after: statuses)
            }
        }
    }

    /// A run that just ended lights up its session.
    private func announce(before: [String: QuorumStatus], after: [String: QuorumStatus]) {
        for (key, status) in after where !status.running && before[key]?.running == true {
            for workspace in Store.shared.workspaces {
                guard self.status(for: workspace)?.key == key, let session = workspace.primary else { continue }
                session.markAttentionIfBackground(reason: status.summary)
            }
        }
    }

    /// quorum in a new tab of the session, where you can watch it.
    func start(_ kind: QuorumStatus.Kind, in workspace: Workspace) {
        guard let pr = workspace.context.pr else { return }
        Store.shared.runInNewTab(Quorum.command(kind, pr: pr, draft: workspace.context.isDraft), in: workspace)
        start(always: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }
}
