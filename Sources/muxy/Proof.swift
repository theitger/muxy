import Foundation

/// A command that proves a checkout's work, from `.wtconfig`:
///
///     [check "frontend"]
///         run = cd frontend && pnpm run lint && pnpm run typecheck
///         paths = frontend/          only when something under it changed
///     [check "backend"]
///         run = devbox run test-backend
///         paths = backend/
///         auto = false               not after every turn, only on request
///
/// Without any, the test command quorum uses for the repository
/// (~/.config/quorum/testcmd/<owner>/<repo>, else the repository's own
/// .quorum/testcmd) is the one check, run on request.
struct ProofCheck: Equatable, Codable {
    var name: String
    var command: String
    /// Path prefixes; empty: always relevant.
    var paths: [String] = []
    /// Runs on its own after every turn of an agent.
    var auto = true

    func applies(to changed: [String]) -> Bool {
        paths.isEmpty || changed.contains { file in paths.contains { file == $0 || file.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
    }

    static func load(root: String) -> [ProofCheck] {
        let file = (root as NSString).appendingPathComponent(WorktreeRecipe.file)
        var checks: [ProofCheck] = []
        if FileManager.default.fileExists(atPath: file),
           let output = Shell.run("/usr/bin/git", ["config", "-f", file, "--get-regexp", #"^check\..*\.(run|paths|auto)$"#], in: root) {
            checks = parse(output)
        }
        if checks.isEmpty, let quorum = quorumCommand(root: root) {
            checks = [ProofCheck(name: L("Tests"), command: quorum, auto: false)]
        }
        return checks
    }

    /// `git config --get-regexp` lines: "check.<name>.<key> <value>".
    static func parse(_ output: String) -> [ProofCheck] {
        var order: [String] = []
        var byName: [String: ProofCheck] = [:]
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].hasPrefix("check.") else { continue }
            let key = pair[0].dropFirst("check.".count)
            guard let dot = key.lastIndex(of: ".") else { continue }
            let name = String(key[..<dot])
            let field = String(key[key.index(after: dot)...])
            guard !name.isEmpty else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = ProofCheck(name: name, command: "")
            }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            switch field {
            case "run": byName[name]?.command = value
            case "paths":
                byName[name]?.paths += value.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            case "auto": byName[name]?.auto = !["false", "no", "off", "0"].contains(value.lowercased())
            default: break
            }
        }
        return order.compactMap { byName[$0] }.filter { !$0.command.isEmpty }
    }

    /// The test command quorum gates its fix rounds with.
    static func quorumCommand(root: String) -> String? {
        if let slug = Issues.repo(of: root) {
            let user = Paths.home + "/.config/quorum/testcmd/" + slug
            if let text = try? String(contentsOfFile: user, encoding: .utf8) {
                let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty { return command }
            }
        }
        let own = (root as NSString).appendingPathComponent(".quorum/testcmd")
        let command = ((try? String(contentsOfFile: own, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

/// What muxy's own run of the checks found, for one state of the files.
struct ProofResult: Equatable, Codable {
    enum Outcome: String, Codable {
        case passed
        case failed
        /// Nothing it looks at changed.
        case skipped
        case cancelled
    }

    struct Entry: Equatable, Codable {
        var name: String
        var command: String
        var outcome: Outcome
        var seconds: Double
        /// The output's last lines: what an agent needs to fix it.
        var tail: String
        var log: String
    }

    /// The files' tree the checks ran on.
    var tree: String
    var entries: [Entry]
    var finished: Date

    var failed: [Entry] { entries.filter { $0.outcome == .failed } }
    var ran: [Entry] { entries.filter { $0.outcome == .passed || $0.outcome == .failed } }
    var verdict: Outcome {
        if entries.contains(where: { $0.outcome == .cancelled }) { return .cancelled }
        if !failed.isEmpty { return .failed }
        return ran.isEmpty ? .skipped : .passed
    }
}

/// Runs a checkout's checks in the background, one after the other, and
/// keeps what they found per checkout. A result belongs to the files it
/// ran on: the same files again (same tree) are not run twice.
@MainActor
final class Proofs: ObservableObject {
    static let shared = Proofs()

    struct Running: Equatable {
        var check: String
        var index: Int
        var count: Int
        var since: Date
    }

    @Published private(set) var results: [String: ProofResult] = [:]
    @Published private(set) var running: [String: Running] = [:]

    /// Checks run on their own after every turn (`auto` ones only).
    static let autoKey = "proofAfterTurn"
    var auto: Bool {
        UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
    }

    private let runner = Runner()
    private var waiters: [String: [(ProofResult?) -> Void]] = [:]

    /// A run asked for while another was going (see `fresh`).
    private struct Queued {
        var root: String
        var checks: [ProofCheck]?
        var session: TerminalSession?
        var then: ((ProofResult?) -> Void)?
    }

    private var queued: [String: Queued] = [:]

    nonisolated static let directory = StateDirectory.path + "/proofs"

    func result(for checkout: String?) -> ProofResult? {
        checkout.flatMap { results[$0] }
    }

    func isRunning(_ checkout: String?) -> Bool {
        checkout.map { running[$0] != nil } ?? false
    }

    /// The agent ended a turn: its auto checks run, when there are any.
    func turnEnded(in session: TerminalSession) {
        guard auto, let checkout = session.context.checkout, let root = session.context.root else { return }
        Task.detached(priority: .utility) {
            let checks = ProofCheck.load(root: root).filter(\.auto)
            guard !checks.isEmpty else { return }
            await MainActor.run { self.run(checkout: checkout, root: root, checks: checks, session: session) }
        }
    }

    /// Runs all of a checkout's checks (or `checks`), then calls back with
    /// the result. A run already going for it is joined, not doubled;
    /// `fresh` waits for it instead and then runs again, on the files as
    /// they are by then and with exactly `checks`.
    func run(
        checkout: String, root: String, checks: [ProofCheck]? = nil, session: TerminalSession? = nil,
        fresh: Bool = false, then: ((ProofResult?) -> Void)? = nil
    ) {
        if fresh, running[checkout] != nil {
            queued[checkout] = Queued(root: root, checks: checks, session: session, then: then)
            return
        }
        if let then { waiters[checkout, default: []].append(then) }
        guard running[checkout] == nil else { return }
        running[checkout] = Running(check: L("Preparing"), index: 0, count: 0, since: Date())
        let runner = runner
        Task.detached(priority: .utility) {
            let all = checks ?? ProofCheck.load(root: root)
            let result = Self.prove(checkout: checkout, root: root, checks: all, runner: runner) { name, index, count in
                Task { @MainActor in
                    self.running[checkout] = Running(check: name, index: index, count: count, since: Date())
                }
            }
            await MainActor.run { self.finish(checkout: checkout, result: result, session: session) }
        }
    }

    /// Results from an earlier run on the same files (kept per tree on
    /// disk): after a restart the cards know again what was proven.
    func recall(_ checkouts: [String]) {
        let missing = checkouts.filter { results[$0] == nil && running[$0] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: [String: ProofResult] = [:]
            for checkout in missing {
                if let tree = WorkState.snapshot(of: checkout)?.tree, let result = Self.cached(tree: tree) {
                    found[checkout] = result
                }
            }
            let recalled = found
            await MainActor.run {
                for (checkout, result) in recalled where self.results[checkout] == nil { self.results[checkout] = result }
            }
        }
    }

    func cancel(checkout: String) {
        runner.cancel(checkout)
    }

    private func finish(checkout: String, result: ProofResult?, session: TerminalSession?) {
        running[checkout] = nil
        // No result (the files couldn't be read): no old verdict either.
        results[checkout] = result
        if let session, result?.verdict == .failed {
            session.markAttentionIfBackground(reason: L("failed its checks"))
        }
        let pending = waiters.removeValue(forKey: checkout) ?? []
        pending.forEach { $0(result) }
        if let next = queued.removeValue(forKey: checkout) {
            run(checkout: checkout, root: next.root, checks: next.checks, session: next.session, then: next.then)
        }
    }

    /// Asks the agent to fix what failed: the check, its command and the
    /// output's end go into its prompt.
    @discardableResult
    static func sendFailures(_ result: ProofResult, to session: TerminalSession) -> Bool {
        let parts = result.failed.map { entry in
            "muxy ran the check \"\(entry.name)\" (`\(entry.command)`) on your work and it failed. The end of its output:\n\n```\n\(entry.tail)\n```"
        }
        guard !parts.isEmpty else { return false }
        let text = parts.joined(separator: "\n\n") + "\n\nFind the cause and fix it, then say in one sentence what it was."
        return RemoteState.type(text, enter: true, into: session)
    }

    // MARK: Running (off the main thread)

    nonisolated static func prove(
        checkout: String, root: String, checks: [ProofCheck], runner: Runner,
        progress: @escaping @Sendable (String, Int, Int) -> Void
    ) -> ProofResult? {
        guard !checks.isEmpty, let snapshot = WorkState.snapshot(of: checkout) else { return nil }
        // Only what passed is remembered, per command: a failure (flaky,
        // Docker down, a fixed command) always runs again.
        if let cached = cached(tree: snapshot.tree), checks.allSatisfy({ check in
            cached.entries.contains { $0.name == check.name && $0.command == check.command && ($0.outcome == .passed || $0.outcome == .skipped) }
        }) {
            return cached
        }
        let base = WorkState.base(of: checkout, root: root) ?? snapshot.head
        let changed = WorkState.changedFiles(from: base, to: snapshot.commit, in: checkout)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var entries: [ProofResult.Entry] = []
        for (index, check) in checks.enumerated() {
            guard check.applies(to: changed) else {
                entries.append(.init(name: check.name, command: check.command, outcome: .skipped, seconds: 0, tail: "", log: ""))
                continue
            }
            progress(check.name, index + 1, checks.count)
            let log = directory + "/\(snapshot.tree.prefix(12))-\(index).log"
            let began = Date()
            let outcome = runner.run(check.command, in: checkout, log: log, key: checkout)
            entries.append(.init(
                name: check.name, command: check.command, outcome: outcome,
                seconds: Date().timeIntervalSince(began), tail: tail(of: log), log: log
            ))
            if outcome == .cancelled { break }
        }
        let result = ProofResult(tree: snapshot.tree, entries: entries, finished: Date())
        if result.verdict == .passed || result.verdict == .skipped { store(result) }
        return result
    }

    nonisolated private static func cachePath(_ tree: String) -> String { directory + "/\(tree).json" }

    nonisolated static func cached(tree: String) -> ProofResult? {
        guard let data = FileManager.default.contents(atPath: cachePath(tree)) else { return nil }
        return try? JSONDecoder().decode(ProofResult.self, from: data)
    }

    nonisolated private static func store(_ result: ProofResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        FileManager.default.createFile(atPath: cachePath(result.tree), contents: data)
    }

    /// The log's last 60 lines (at most 6000 characters).
    nonisolated static func tail(of log: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: log) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n")
        return String(stripANSI(lines).suffix(6000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Colors and cursor moves out: an agent reads the words.
    nonisolated static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    /// One check at a time per checkout, each cancellable.
    final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [String: Process] = [:]
        private var cancelled: Set<String> = []

        func cancel(_ key: String) {
            let pid: pid_t? = lock.withLock {
                cancelled.insert(key)
                return processes[key]?.processIdentifier
            }
            if let pid { Self.killTree(pid, signal: SIGTERM) }
        }

        /// The shell and everything it started (test runners, Compose):
        /// SIGTERM to the shell alone would orphan them.
        static func killTree(_ pid: pid_t, signal: Int32) {
            if let children = Shell.run("/usr/bin/pgrep", ["-P", String(pid)], in: "/") {
                for child in children.split(separator: "\n").compactMap({ pid_t($0) }) {
                    killTree(child, signal: signal)
                }
            }
            kill(pid, signal)
        }

        /// Your login shell runs it, so it finds what your terminal finds.
        func run(_ command: String, in directory: String, log: String, key: String) -> ProofResult.Outcome {
            FileManager.default.createFile(atPath: log, contents: nil)
            guard let out = FileHandle(forWritingAtPath: log) else { return .failed }
            defer { try? out.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Paths.userShell)
            process.arguments = ["-l", "-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = out
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Shell.path
            env["MUXY_PROOF"] = "1"
            env["CI"] = "1"
            env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            let started: Bool = lock.withLock {
                guard !cancelled.contains(key) else { return false }
                processes[key] = process
                return (try? process.run()) != nil
            }
            guard started else {
                lock.withLock { _ = cancelled.remove(key) }
                return .cancelled
            }
            // Long test suites are fine; a hung one is not.
            var finished = exited.wait(timeout: .now() + 2700) == .success
            if !finished {
                Self.killTree(process.processIdentifier, signal: SIGTERM)
                finished = exited.wait(timeout: .now() + 5) == .success
                if !finished {
                    Self.killTree(process.processIdentifier, signal: SIGKILL)
                    finished = exited.wait(timeout: .now() + 5) == .success
                }
            }
            // A cancel kills the tree; wait for the shell to actually go.
            if !finished || process.isRunning { _ = exited.wait(timeout: .now() + 10) }
            let wasCancelled = lock.withLock {
                processes[key] = nil
                return cancelled.remove(key) != nil
            }
            if wasCancelled { return .cancelled }
            // Still running after SIGKILL: reading its status would throw.
            guard !process.isRunning else { return .failed }
            return process.terminationReason == .exit && process.terminationStatus == 0 ? .passed : .failed
        }
    }
}
