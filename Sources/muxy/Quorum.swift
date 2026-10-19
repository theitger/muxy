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

    var isClean: Bool { blockers == 0 && critical == 0 }

    /// Finished and quorum says it worked: converged, nothing open. A run
    /// that failed or was cancelled is never this, whatever its counts.
    var succeeded: Bool {
        !running && isClean && ["converged", "ok", "clean", "merged", "success"].contains(outcome ?? "")
    }

    /// One line for a card.
    var summary: String {
        if running {
            let what = kind == .babysit ? L("quorum babysits") : L("quorum reviews")
            var parts = [what]
            if let round { parts.append(L("round %d", round)) }
            if let phase { parts.append(phase) }
            return parts.joined(separator: " · ")
        }
        let findings = blockers + critical
        switch outcome {
        case "converged", "clean", "merged", "ok", "success":
            return findings == 0 ? L("quorum: clean") : L("quorum: %d open", findings)
        case nil:
            return findings == 0 ? L("quorum: no blockers") : L("quorum: %d blockers", findings)
        case let other?:
            return L("quorum: %@", other)
        }
    }
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
                blockers: progress["blockers"] as? Int ?? 0, critical: progress["critical"] as? Int ?? 0,
                date: date(progress["updated_at"]) ?? modified, runDirectory: dir
            )
        } else if let target = json(dir + "/target.json"), let repo = target["repo"] as? String,
                  let number = target["number"] as? Int {
            status = QuorumStatus(kind: kind, key: "\(repo)#\(number)", running: alive, date: modified, runDirectory: dir)
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
                date: date(entry["ended_at"]) ?? .distantPast, runDirectory: entry["run_dir"] as? String
            )
        }
    }

    /// The shell line that hands a PR to quorum.
    static func command(_ kind: QuorumStatus.Kind, pr: Int) -> String {
        "quorum \(kind.rawValue) \(pr)"
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
        Store.shared.runInNewTab(Quorum.command(kind, pr: pr), in: workspace)
        start(always: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }
}
