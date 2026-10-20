import Foundation

/// One quorum run as a timeline: each review with what it found, each fix
/// with its commits and what the fixing agent said, CI, and how it ended.
/// Read from the files quorum keeps anyway (see QuorumStatus): a babysit's
/// folder has its progress, `logs/rounds.log`, a log and a message per
/// fix; its reviews are the review folders of the same PR from while it ran.
struct QuorumRun: Equatable {
    struct Finding: Equatable, Hashable {
        enum Severity: String, CaseIterable { case blocker, critical, suggestion, question }
        var severity: Severity
        /// "path:12-13", when the finding names one.
        var location: String?
        var text: String
    }

    struct Step: Equatable, Identifiable {
        enum Kind: Equatable { case review, fix, testFix, pushFix, ciFix, suggestions, ci, end }
        var kind: Kind
        /// The round or the attempt, as quorum counts it.
        var number: Int?
        var date: Date
        var running = false
        var ok: Bool?
        var blockers = 0
        var critical = 0
        var suggestions = 0
        /// The commit it reviewed, or the commits it made.
        var head: String?
        var commits: [String] = []
        var findings: [Finding] = []
        /// What the review summed up, or the fixing agent said.
        var summary: String?
        /// The fixing agent arguing a finding isn't one.
        var dispute: String?
        /// A running review: reviewers done of all, and where it is.
        var reviewersDone = 0
        var reviewers = 0
        var stage: String?
        /// The file to open for more: a review's report, a step's log.
        var file: String?
        /// Why it ended, for the end.
        var reason: String?

        var id: String { "\(kind)-\(number ?? 0)-\(date.timeIntervalSince1970)" }
        var open: Int { blockers + critical }
    }

    var status: QuorumStatus
    var started: Date?
    var ended: Date?
    /// The models it reviews and fixes with ("gpt-5.6-luna · medium").
    var reviewModel: String?
    var fixModel: String?
    var ci: String?
    var steps: [Step] = []

    /// The newest review: what is open now.
    var latestReview: Step? { steps.last { $0.kind == .review } }

    var rounds: Int { steps.filter { $0.kind == .review }.count }

    // MARK: Reading

    static func load(_ status: QuorumStatus, now: Date = Date(), cache: String = Quorum.cache) -> QuorumRun? {
        guard let dir = status.runDirectory else { return nil }
        var run = QuorumRun(status: status)
        if status.kind == .review {
            if let review = review(in: dir) { run.steps = [review] }
            run.started = run.steps.first?.date
        } else {
            babysit(in: dir, into: &run, now: now, cache: cache)
        }
        if !status.running, let outcome = status.outcome {
            run.steps.append(Step(kind: .end, date: run.ended ?? status.date, ok: status.succeeded ? true : status.interrupted ? nil : false,
                                  summary: outcome, file: nil, reason: status.reason))
        }
        return run
    }

    private static func babysit(in dir: String, into run: inout QuorumRun, now: Date, cache: String) {
        let progress = json(dir + "/progress.json") ?? [:]
        run.started = date(progress["started_at"]) ?? stamp(of: dir)
        run.ended = run.status.running ? nil : (run.status.outcome != nil ? run.status.date : date(progress["updated_at"]))
        run.reviewModel = model(progress["review_model"])
        run.fixModel = model(progress["fix_model"])
        run.ci = progress["ci"] as? String
        let phase = run.status.running ? progress["phase"] as? String : nil

        var steps: [Step] = []
        // Its reviews: the PR's review folders from while it ran.
        if let start = run.started, let prefix = prefix(of: dir) {
            let end = run.ended.map { $0.addingTimeInterval(60) } ?? now
            let folder = cache + "/reviews"
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasPrefix(prefix) }.sorted()
            for name in names {
                let path = folder + "/" + name
                guard let when = stamp(of: path), when >= start.addingTimeInterval(-60), when <= end,
                      var review = review(in: path) else { continue }
                review.running = review.running && run.status.running
                steps.append(review)
            }
        }
        for (index, _) in steps.enumerated() { steps[index].number = index + 1 }

        // Its fixes: a log each, the commits from rounds.log, the agent's words.
        let commits = rounds(dir + "/logs/rounds.log")
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: dir + "/logs")) ?? []
        for name in logs.sorted() {
            guard let (kind, number, title) = fixStep(name) else { continue }
            let path = dir + "/logs/" + name
            let base = (name as NSString).deletingPathExtension
            steps.append(Step(
                kind: kind, number: number, date: modified(path) ?? run.started ?? now,
                commits: commits[title] ?? [],
                summary: text(dir + "/messages/" + base + ".md"),
                dispute: disputes(in: dir + "/messages", of: base),
                file: path
            ))
        }
        if let ci = run.ci, FileManager.default.fileExists(atPath: dir + "/logs/ci-last.log") {
            let path = dir + "/logs/ci-last.log"
            steps.append(Step(kind: .ci, date: modified(path) ?? now, running: phase == "ci",
                              ok: phase == "ci" ? nil : ci == "green", summary: ci, file: path))
        }
        steps.sort { $0.date < $1.date }
        // The step it is on: the newest one of the phase it says.
        if let phase, let index = steps.lastIndex(where: { Self.phase(of: $0.kind) == phase }), index == steps.count - 1,
           steps[index].kind != .review {
            steps[index].running = steps[index].commits.isEmpty
        }
        run.steps = steps
    }

    /// One review folder: its counts, what it found, or how far it is.
    static func review(in dir: String) -> Step? {
        let output = dir + "/output"
        guard let when = stamp(of: dir) ?? modified(dir) else { return nil }
        var step = Step(kind: .review, date: when)
        if let findings = json(output + "/findings.json") {
            step.blockers = findings["blockers"] as? Int ?? 0
            step.critical = findings["critical"] as? Int ?? 0
            step.suggestions = findings["suggestions"] as? Int ?? 0
            step.head = (findings["head_sha"] as? String).map { String($0.prefix(10)) }
            step.reviewers = findings["reviewers_requested"] as? Int ?? 0
            step.reviewersDone = findings["reviewers_succeeded"] as? Int ?? 0
            step.ok = step.open == 0
            let report = (findings["comment_file"] as? String) ?? output + "/final-pr-comment.md"
            if let comment = text(report) {
                let parsed = parse(comment)
                step.findings = parsed.findings
                step.summary = parsed.summary
            }
            step.file = report
            return step
        }
        // Not done: how far, from its event log.
        let alive = pid(in: dir).map { kill($0, 0) == 0 } ?? false
        guard alive else { return nil }
        step.running = true
        let events = (text(output + "/events.log") ?? "").split(separator: "\n").map(String.init)
        step.reviewersDone = events.filter { $0.hasPrefix("ok ") }.count
        let started = ((try? FileManager.default.contentsOfDirectory(atPath: output)) ?? [])
            .filter { $0.hasPrefix("reviewer-") && $0.hasSuffix(".log") }.count
        step.reviewers = max(started, Int(QuorumConfig.read()["REVIEWERS"] ?? "") ?? 6, step.reviewersDone)
        step.stage = events.last?.split(separator: " ").first.map(String.init)
        return step
    }

    /// quorum's review comment: the summary and each finding by severity.
    static func parse(_ markdown: String) -> (summary: String?, findings: [Finding]) {
        var findings: [Finding] = []
        var summary: [String] = []
        var section: String?
        var current: (Finding.Severity, String)?
        func flush() {
            guard let (severity, item) = current else { return }
            findings.append(finding(severity, item))
            current = nil
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                section = String(line.dropFirst(3)).lowercased()
                continue
            }
            guard let section else { continue }
            if section == "summary" {
                if !line.isEmpty { summary.append(line) }
                continue
            }
            guard let severity = severity(section) else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                current = (severity, String(line.dropFirst(2)))
            } else if !line.isEmpty, let open = current {
                current = (open.0, open.1 + " " + line)
            }
        }
        flush()
        return (summary.isEmpty ? nil : summary.joined(separator: " "), findings)
    }

    private static func severity(_ section: String) -> Finding.Severity? {
        if section.hasPrefix("blocker") { return .blocker }
        if section.hasPrefix("critical") { return .critical }
        if section.hasPrefix("suggestion") { return .suggestion }
        if section.hasPrefix("question") { return .question }
        return nil
    }

    /// "`path:12` — what is wrong" → location and text.
    private static func finding(_ severity: Finding.Severity, _ item: String) -> Finding {
        guard item.hasPrefix("`"), let close = item.dropFirst().firstIndex(of: "`") else {
            return Finding(severity: severity, text: item)
        }
        let location = String(item[item.index(after: item.startIndex)..<close])
        var rest = item[item.index(after: close)...].trimmingCharacters(in: .whitespaces)
        for dash in ["—", "–", "-", ":"] where rest.hasPrefix(dash) {
            rest = String(rest.dropFirst(dash.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // A location is a path; a finding that only starts with code is text.
        guard location.contains("/") || location.contains(".") else { return Finding(severity: severity, text: item) }
        return Finding(severity: severity, location: location, text: rest)
    }

    /// rounds.log: "Review fix round 1:" then a commit per line.
    static func rounds(_ path: String) -> [String: [String]] {
        var groups: [String: [String]] = [:]
        var title: String?
        for line in (text(path) ?? "").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let commit = trimmed.range(of: #"^[0-9a-f]{7,40} "#, options: .regularExpression) != nil
            if !commit, trimmed.hasSuffix(":") {
                title = String(trimmed.dropLast()).lowercased()
            } else if let title, commit {
                groups[title, default: []].append(trimmed)
            }
        }
        return groups
    }

    /// A step's log name → its kind, number and its title in rounds.log.
    static func fixStep(_ name: String) -> (Step.Kind, Int?, String)? {
        let base = (name as NSString).deletingPathExtension
        guard name.hasSuffix(".log") else { return nil }
        let kinds: [(String, Step.Kind, String)] = [
            ("fix-round-", .fix, "review fix round"), ("test-fix-", .testFix, "test fix"),
            ("push-fix-", .pushFix, "push fix"), ("ci-fix-", .ciFix, "ci fix")
        ]
        for (prefix, kind, title) in kinds where base.hasPrefix(prefix) {
            guard let number = Int(base.dropFirst(prefix.count)) else { return nil }
            return (kind, number, "\(title) \(number)")
        }
        if base == "suggestion-round" { return (.suggestions, nil, "suggestion round") }
        return nil
    }

    private static func phase(of kind: Step.Kind) -> String? {
        switch kind {
        case .review: "review"
        case .fix, .suggestions: "fix"
        case .testFix: "tests"
        case .pushFix: "push"
        case .ciFix: "ci_fix"
        case .ci: "ci"
        case .end: nil
        }
    }

    /// The fixing agent's case against findings it didn't fix
    /// ("fix-round-1-dispute.md", "fix-round-1-dispute-1.md", …).
    static func disputes(in messages: String, of base: String) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: messages)) ?? [])
            .filter { $0.hasPrefix(base + "-dispute") && $0.hasSuffix(".md") }.sorted()
        let texts = names.compactMap { text(messages + "/" + $0) }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// Blockers and critical findings a fix took care of with a commit, and
    /// those it argued away without one: both end a round clean, only one
    /// changed the code.
    var resolved: (fixed: Int, disputed: Int) {
        var fixed = 0, disputed = 0
        for (index, step) in steps.enumerated() where step.kind == .review && step.open > 0 {
            guard let fix = steps[(index + 1)...].first(where: { $0.kind == .fix || $0.kind == .review }), fix.kind == .fix else { continue }
            if fix.commits.isEmpty { disputed += step.open } else { fixed += step.open }
        }
        return (fixed, disputed)
    }

    /// "moto-nrw-project-phoenix-pr-4399-20261019-224308" → "…-pr-4399-".
    static func prefix(of dir: String) -> String? {
        let name = (dir as NSString).lastPathComponent
        guard let range = name.range(of: #"-pr-\d+-"#, options: .regularExpression) else { return nil }
        return String(name[..<range.upperBound])
    }

    /// When a run folder was made, from its name (local time).
    static func stamp(of dir: String) -> Date? {
        let name = (dir as NSString).lastPathComponent
        guard let range = name.range(of: #"\d{8}-\d{6}$"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(name[range]))
    }

    private static func model(_ value: Any?) -> String? {
        guard let model = value as? [String: Any], let name = model["model"] as? String else { return nil }
        return [name, model["effort"] as? String].compactMap { $0 }.joined(separator: " · ")
    }

    private static func pid(in dir: String) -> pid_t? {
        text(dir + "/run.pid").flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func text(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

/// The quorum muxy reads: which version it was made for, and whether the
/// one installed writes what muxy understands. A newer quorum may change
/// its files; the view then says so instead of showing less in silence.
enum QuorumCompat {
    /// The quorum release muxy's reading was last checked against.
    static let tested = "1.16.0"
    /// The file schemas muxy reads, as quorum numbers them.
    static let schemas = ["output/findings.json": 1, "target.json": 2, "divergence-trace.json": 1]

    /// The installed version, asked once (`quorum version` only prints it).
    nonisolated(unsafe) private static var asked: String??

    static func installed() -> String? {
        if let asked { return asked }
        let found = Shell.find("quorum").flatMap { Shell.run($0, ["version"], in: Paths.home) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.split(separator: " ").last.map(String.init) }
        asked = .some(found)
        return found
    }

    /// Something to say about it, or nil when all is as muxy knows it.
    static func warning(for dir: String?, installed: String? = installed()) -> String? {
        if let dir {
            for (file, known) in schemas.sorted(by: { $0.key < $1.key }) {
                guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let schema = object["schema"] as? Int, schema != known else { continue }
                return L("quorum writes %@ in a newer form (schema %d): parts of this view may be missing.", file, schema)
            }
        }
        if let installed, newer(installed, than: tested) {
            return L("quorum %@ is newer than the %@ muxy was checked against: if something looks off, that's why.", installed, tested)
        }
        return nil
    }

    static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
