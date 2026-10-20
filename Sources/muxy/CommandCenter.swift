import AppKit

/// Where this muxy keeps the files other programs talk to it through. The
/// installed app and a development build each have their own, so `muxy`
/// commands reach the right one: the installed app by default, a dev build
/// from inside its own terminals (they carry MUXY_STATE_DIR). MUXY_STATE_DIR
/// also overrides it at launch, for a second instance on the side.
enum StateDirectory {
    static let installed = Paths.home + "/.local/state/muxy"

    static let path: String = {
        if let custom = ProcessInfo.processInfo.environment["MUXY_STATE_DIR"], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom).standardized.path
        }
        if Paths.isTesting {
            return (NSTemporaryDirectory() as NSString).appendingPathComponent("muxy-tests-\(getpid())")
        }
        return Paths.isApp ? installed : Paths.home + "/.local/state/muxy-dev"
    }()

    /// What a terminal needs to reach this muxy: nothing for the installed
    /// app (the CLI's default), the directory for any other.
    static var environment: [String: String] {
        path == installed ? [:] : ["MUXY_STATE_DIR": path]
    }
}

/// The `muxy` command line tool's channel (Scripts/muxy): a request is a
/// small JSON file renamed into `<state>/commands`, the answer one renamed
/// into `<state>/replies` under the same name. `<state>/muxy.pid` says this
/// muxy is up and listening. Requests only ever pick from fixed actions:
/// nothing in them is run, malformed or oversized ones are dropped.
@MainActor
final class CommandCenter {
    static let shared = CommandCenter()

    private let commands = StateDirectory.path + "/commands"
    private let replies = StateDirectory.path + "/replies"
    private let scratch = StateDirectory.path + "/tmp"
    private let pidFile = StateDirectory.path + "/muxy.pid"

    /// Bigger than any real request (a long prompt); more is not one.
    static let maxRequestBytes = 64 * 1024
    /// The CLI gives up after a few seconds: a request that waited longer
    /// (muxy was hung or asleep) is dropped rather than acted on late.
    static let maxRequestAge: TimeInterval = 30

    private weak var store: Store?
    private var source: DispatchSourceFileSystemObject?

    func start(store: Store) {
        guard self.store == nil else { return }
        self.store = store
        let fm = FileManager.default
        for dir in [commands, replies, scratch] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(commands, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        // Listening from here on: the CLI waits for this file.
        try? "\(getpid())\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [pidFile] _ in
            try? FileManager.default.removeItem(atPath: pidFile)
        }
        drain()
    }

    private func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: commands) else { return }
        for name in names {
            let path = commands + "/" + name
            let request = Self.read(path)
            try? fm.removeItem(atPath: path)
            guard let request, let id = Self.requestID(name) else { continue }
            handle(request) { [weak self] reply in self?.answer(id, reply) }
        }
        sweepReplies()
    }

    /// The request's name is its reply's name: plain characters only.
    private static func requestID(_ name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        let id = String(name.dropLast(5))
        return id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil ? id : nil
    }

    /// A regular file of ours, small and recent, holding a JSON object.
    private static func read(_ path: String) -> [String: Any]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = attributes[.size] as? NSNumber, size.intValue <= maxRequestBytes,
              let modified = attributes[.modificationDate] as? Date,
              modified.timeIntervalSinceNow > -maxRequestAge,
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    struct Reply: Error {
        var ok: Bool
        var output: String
    }

    private func answer(_ id: String, _ reply: Reply) {
        let body: [String: Any] = reply.ok ? ["ok": true, "output": reply.output] : ["ok": false, "error": reply.output]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        // Written aside, then renamed: the CLI never reads half an answer.
        let temp = scratch + "/reply-\(id)"
        guard FileManager.default.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp, replies + "/" + id + ".json") != 0 { try? FileManager.default.removeItem(atPath: temp) }
    }

    /// Answers nobody picked up (the CLI gave up or was killed).
    private func sweepReplies() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: replies)) ?? [] {
            let path = replies + "/" + name
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            if modified.timeIntervalSinceNow < -60 { try? fm.removeItem(atPath: path) }
        }
    }

    // MARK: - Requests

    private func handle(_ request: [String: Any], reply: @escaping (Reply) -> Void) {
        guard let store else { return }
        func text(_ key: String, max: Int) -> String? {
            guard let value = request[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(max))
        }
        switch request["command"] as? String {
        case "status":
            let rows = StatusReport.all(in: store)
            reply(Reply(ok: true, output: text("format", max: 10) == "json" ? StatusReport.json(rows) : StatusReport.table(rows)))
        case "focus":
            guard let id = text("session", max: 64) else { return reply(Reply(ok: false, output: "focus needs a session id")) }
            switch resolve(id) {
            case let .failure(problem): reply(problem)
            case let .success((workspace, tab)):
                store.select(workspace, session: tab)
                store.window(of: workspace)?.bringToFront()
                reply(Reply(ok: true, output: ""))
            }
        case "notify":
            notify(
                message: Self.oneLine(text("message", max: 2000)), title: Self.oneLine(text("title", max: 200)),
                session: text("session", max: 64), implicit: request["implicit"] as? String == "1", reply: reply
            )
        case "new":
            newSession(
                directory: text("repo", max: 4096), agent: text("agent", max: 10), worktree: text("worktree", max: 4),
                branch: text("branch", max: 200), issue: text("issue", max: 300), prompt: text("prompt", max: 32 * 1024),
                reply: reply
            )
        case "proof", "proof-status":
            guard let id = text("session", max: 64) else { return reply(Reply(ok: false, output: "proof needs a session (or run it inside one)")) }
            switch resolve(id) {
            case let .failure(problem): reply(problem)
            case let .success((workspace, _)):
                proof(workspace, start: request["command"] as? String == "proof", reply: reply)
            }
        case "land":
            guard let id = text("session", max: 64) else { return reply(Reply(ok: false, output: "land needs a session (or run it inside one)")) }
            switch resolve(id) {
            case let .failure(problem): reply(problem)
            case let .success((workspace, _)):
                guard Landing.shared.canLand(workspace) else {
                    return reply(Reply(ok: false, output: "nothing to land: the session has no open pull request"))
                }
                guard Acceptance.shared.covers(workspace) else {
                    Store.shared.window(of: workspace)?.openAcceptance(workspace)
                    return reply(Reply(ok: false, output: "inspect and accept the implementation in muxy first"))
                }
                Landing.shared.land(workspace)
                reply(Reply(ok: true, output: "landing \(workspace.title)"))
            }
        #if DEBUG
        case "debug":
            // Development only: drive the UI and photograph a window
            // without screen-recording rights.
            DebugDriver.handle(action: text("action", max: 40) ?? "", value: text("value", max: 4096), store: store, reply: { reply(Reply(ok: $0, output: $1)) })
        #endif
        default:
            reply(Reply(ok: false, output: "unknown command; is the muxy app older than this muxy tool?"))
        }
    }

    /// Control characters out, so a message can't fake lines in a banner.
    private static func oneLine(_ text: String?) -> String? {
        text.map { String($0.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }) }
    }

    /// A session by any of its ids: the session's own (`muxy status`) or
    /// one of its tabs' (MUXY_SESSION), whole or a unique start of it.
    private func resolve(_ id: String) -> Result<(Workspace, TerminalSession?), Reply> {
        guard let store else { return .failure(Reply(ok: false, output: "muxy is shutting down")) }
        let wanted = id.uppercased()
        var matches: [(Workspace, TerminalSession?)] = []
        for workspace in store.workspaces {
            if workspace.id.uuidString == wanted { return .success((workspace, nil)) }
            if let tab = workspace.sessions.first(where: { $0.id.uuidString == wanted }) { return .success((workspace, tab)) }
            guard wanted.count >= 4 else { continue }
            if workspace.id.uuidString.hasPrefix(wanted) { matches.append((workspace, nil)) }
            for tab in workspace.sessions where tab.id.uuidString.hasPrefix(wanted) { matches.append((workspace, tab)) }
        }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure(Reply(ok: false, output: "no session \(id) (see muxy status)"))
        default: return .failure(Reply(ok: false, output: "\(id) matches \(matches.count) sessions; use more of the id"))
        }
    }

    // MARK: proof

    /// Starts the session's checks (`proof`) or says where they stand
    /// (`proof-status`). The first line is the state: running, passed,
    /// failed, skipped, cancelled or none; then one line per check.
    private func proof(_ workspace: Workspace, start: Bool, reply: (Reply) -> Void) {
        guard let checkout = workspace.context.checkout, let root = workspace.context.root else {
            return reply(Reply(ok: false, output: "not a git checkout"))
        }
        let proofs = Proofs.shared
        if start, proofs.running[checkout] == nil {
            guard !ProofCheck.load(root: root).isEmpty else {
                return reply(Reply(ok: false, output: "no checks: add [check \"name\"] run = … to .wtconfig"))
            }
            proofs.run(checkout: checkout, root: root, session: workspace.primary)
        }
        if let running = proofs.running[checkout] {
            return reply(Reply(ok: true, output: "running\n\(running.check)"))
        }
        guard let result = proofs.result(for: checkout) else { return reply(Reply(ok: true, output: "none")) }
        var lines = [result.verdict.rawValue]
        for entry in result.entries {
            lines.append("\(entry.outcome.rawValue)\t\(entry.name)\t\(entry.command)")
            if entry.outcome == .failed { lines.append(entry.tail) }
        }
        reply(Reply(ok: true, output: lines.joined(separator: "\n")))
    }

    // MARK: notify

    /// The session wants you: its card lights up with the message, a toast
    /// says it, a banner too when muxy is in the background. Without a
    /// session, just the toast and the banner.
    private func notify(message: String?, title: String?, session: String?, implicit: Bool, reply: (Reply) -> Void) {
        guard let store, let message else { return reply(Reply(ok: false, output: "notify needs a message")) }
        var target: (Workspace, TerminalSession?)?
        if let session {
            switch resolve(session) {
            case let .success(found): target = found
            // MUXY_SESSION from a session that is gone: still worth saying.
            case .failure where implicit: break
            case let .failure(problem): return reply(problem)
            }
        }
        guard let target, let tab = target.1 ?? target.0.featured else {
            let heading = title ?? "muxy"
            (store.activeWindow ?? store.windows.first)?.show("\(heading): \(message)", seconds: 5)
            Notifier.post(title: heading, body: message, session: nil)
            return reply(Reply(ok: true, output: ""))
        }
        let workspace = target.0
        let heading = title ?? workspace.title
        // Like any other news: only what you aren't looking at lights up.
        if tab.terminalView.window == nil {
            tab.needsAttention = true
            tab.notice = message
        }
        store.window(of: workspace)?.show("\(heading): \(message)", seconds: 5)
        Notifier.post(title: heading, body: message, session: tab)
        reply(Reply(ok: true, output: ""))
    }

    // MARK: new

    /// A session as the ⌘N panel would start it; what isn't given comes
    /// from the panel's last choices. Answers with the new session's id.
    func newSession(
        directory: String?, agent: String?, worktree: String?, branch: String?, issue: String?, prompt: String?,
        reply: @escaping (Reply) -> Void
    ) {
        guard let directory, directory.hasPrefix("/") else { return reply(Reply(ok: false, output: "new needs a repository folder")) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return reply(Reply(ok: false, output: "no such folder: \(directory)"))
        }
        let defaults = UserDefaults.standard
        var choice = agent ?? AgentKind.preferred(in: defaults).rawValue
        // The panel's last choice was both agents: one, unless asked for both.
        if agent == nil, choice == NewSessionView.both { choice = AgentKind.claude.rawValue }
        guard choice == "none" || choice == "shell" || choice == NewSessionView.both || AgentKind(rawValue: choice) != nil else {
            return reply(Reply(ok: false, output: "unknown agent \(choice): claude, codex, both or none"))
        }
        let wantsWorktree = worktree.map { $0 == "on" } ?? (defaults.object(forKey: "newSessionWorktree") as? Bool ?? true)
        if let branch, !Self.plausibleBranch(branch) {
            return reply(Reply(ok: false, output: "not a usable branch name: \(branch)"))
        }
        if let issue, issue.range(of: #"^[A-Za-z0-9._/#:-]{1,300}$"#, options: .regularExpression) == nil {
            return reply(Reply(ok: false, output: "not an issue reference: \(issue)"))
        }
        Task.detached(priority: .userInitiated) {
            // The panel offers a worktree only inside a repository.
            let inRepo = Launcher.mainCheckout(of: directory) != nil
            // The issue itself, like the panel looks it up. Unreachable
            // (gh missing, offline): the agent gets the reference only.
            var found: Issue?
            if let issue {
                guard let ref = IssueRef.parse(issue) else {
                    return reply(Reply(ok: false, output: "not an issue reference: \(issue)"))
                }
                switch Issues.view(ref.number, repo: ref.repo ?? Issues.repo(of: directory), in: directory) {
                case let .found(resolved): found = resolved
                case .notFound: return reply(Reply(ok: false, output: "no such issue: \(issue)"))
                case .pullRequest: return reply(Reply(ok: false, output: "\(issue) is a pull request, not an issue"))
                case .unavailable: break
                }
            }
            let issueFound = found
            await MainActor.run {
                guard let store = self.store else { return }
                let window = store.activeWindow ?? store.windows.first ?? {
                    let model = store.makeWindow()
                    store.openWindow?(id: "main", value: model.id)
                    return model
                }()
                if choice == NewSessionView.both, inRepo, let root = Launcher.mainCheckout(of: directory) {
                    if let issueFound {
                        FanOut.launch(issue: issueFound, root: root, agents: AgentKind.allCases, in: window)
                    } else {
                        FanOut.launch(prompt: prompt ?? "", root: root, agents: AgentKind.allCases, branch: branch, in: window)
                    }
                    reply(Reply(ok: true, output: store.workspaces.suffix(AgentKind.allCases.count).map(\.id.uuidString).joined(separator: "\n")))
                    return
                }
                let spec = SessionSpec(
                    directory: directory, agent: AgentKind(rawValue: choice), prompt: prompt ?? "",
                    worktree: inRepo && wantsWorktree, branch: branch
                )
                if let issue {
                    store.launch(issue: issue, found: issueFound, spec: spec, in: window)
                } else {
                    store.launch(spec, in: window)
                }
                // launch adds the session last.
                reply(Reply(ok: true, output: store.workspaces.last?.id.uuidString ?? ""))
            }
        }
    }

    /// Roughly `git check-ref-format --branch`; git itself has the last word.
    private static func plausibleBranch(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._/-]{1,200}$"#, options: .regularExpression) != nil
            && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.hasSuffix("/") && !name.hasSuffix(".lock")
            && !name.contains("..") && !name.contains("//")
    }
}

extension Store {
    /// `muxy new --issue <ref>`: like an issue picked in the ⌘N panel.
    /// `found` is the issue as gh knows it; nil when gh couldn't say.
    func launch(issue ref: String, found: Issue?, spec: SessionSpec, in window: WindowModel) {
        var spec = spec
        if let found {
            let note = IssueRef.parse(ref)?.note ?? ""
            let extra = [note, spec.prompt].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let issuePrompt = Issues.prompt(for: found, note: extra, localRepo: Issues.repo(of: spec.directory),
                                            agent: spec.agent, implement: Issues.implementSkill(in: spec.directory))
            spec.prompt = [issuePrompt, TaskLedger.shared.instructions(for: found)]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            spec.issue = found
            // Named after the issue, not by the model.
            if let branch = spec.branch, BranchNamer.isPlaceholder(branch) {
                spec.branch = Issues.branchName(for: found)
                spec.autoName = false
            }
        } else {
            let task = "Work on issue \(ref)"
            spec.prompt = spec.prompt.isEmpty ? task : task + "\n\n" + spec.prompt
            // Named after the task, which now always has one.
            if let branch = spec.branch, BranchNamer.isPlaceholder(branch) { spec.autoName = true }
        }
        launch(spec, in: window)
    }
}

/// `muxy status`: every open session, as a table or as JSON (schema in the
/// README; keys only ever get added).
enum StatusReport {
    @MainActor
    static func all(in store: Store) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for (index, window) in store.windows.enumerated() {
            for workspace in window.orderedWorkspaces {
                let context = workspace.context
                let featured = workspace.featured
                var pr: Any = NSNull()
                if let number = context.pr {
                    pr = [
                        "number": number,
                        "state": name(context.prState),
                        "checks": name(context.checks),
                        "draft": context.isDraft,
                        "mergeable": name(context.mergeability),
                        "status": name(workspace.prStatus),
                    ] as [String: Any]
                }
                rows.append([
                    "id": workspace.id.uuidString,
                    "window": index + 1,
                    "onStage": window.selectedWorkspaceID == workspace.id,
                    "title": workspace.title,
                    "repo": context.repo ?? NSNull(),
                    "branch": context.branch ?? NSNull(),
                    "directory": workspace.directory,
                    "folder": context.folder,
                    "agent": featured?.kind?.rawValue ?? NSNull(),
                    "state": name(workspace.agent),
                    "attention": workspace.needsAttention,
                    "notice": workspace.notice ?? NSNull(),
                    "pr": pr,
                    "tabs": workspace.sessions.map { tab -> [String: Any] in
                        [
                            "id": tab.id.uuidString,
                            "agent": tab.kind?.rawValue ?? NSNull(),
                            "state": name(tab.agent),
                            "directory": tab.cwd,
                            "attention": tab.needsAttention,
                        ]
                    },
                ])
            }
        }
        return rows
    }

    // Spelled out, not derived from the case names: renaming a case in
    // the app must not change what scripts read.

    private static func name(_ state: AgentState) -> String {
        switch state {
        case .none: "none"
        case .idle: "idle"
        case .working: "working"
        case .blocked: "blocked"
        case .failed: "failed"
        }
    }

    private static func name(_ state: Git.PullRequest.State) -> String {
        switch state {
        case .open: "open"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    private static func name(_ checks: Checks) -> String {
        switch checks {
        case .none: "none"
        case .pending: "pending"
        case .failed: "failed"
        case .passed: "passed"
        }
    }

    private static func name(_ mergeability: Mergeability) -> String {
        switch mergeability {
        case .unknown: "unknown"
        case .clean: "clean"
        case .conflicting: "conflicting"
        case .behind: "behind"
        case .reviewRequired: "reviewRequired"
        case .changesRequested: "changesRequested"
        case .blocked: "blocked"
        }
    }

    private static func name(_ status: PRStatus) -> String {
        switch status {
        case .none: "none"
        case .running: "running"
        case .fixing: "fixing"
        case .failed: "failed"
        case .conflicts: "conflicts"
        case .draft: "draft"
        case .waiting: "waiting"
        case .ready: "ready"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    static func json(_ rows: [[String: Any]]) -> String {
        let root: [String: Any] = ["version": 1, "sessions": rows]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func table(_ rows: [[String: Any]]) -> String {
        guard !rows.isEmpty else { return "No sessions open." }
        let header = ["ID", "WIN", "STATE", "AGENT", "REPO", "BRANCH", "PR", "TITLE"]
        let lines = rows.map { row -> [String] in
            let pr = (row["pr"] as? [String: Any]).map { "#\($0["number"] ?? "") \($0["status"] ?? "")" } ?? "-"
            let state = "\(row["state"] ?? "")" + ((row["attention"] as? Bool) == true ? "!" : "")
            return [
                String("\(row["id"] ?? "")".prefix(8)), "\(row["window"] ?? "")", state,
                row["agent"] as? String ?? "-", row["repo"] as? String ?? "-", row["branch"] as? String ?? "-",
                pr, String("\(row["title"] ?? "")".prefix(48)),
            ]
        }
        let widths = header.indices.map { column in ([header] + lines).map { $0[column].count }.max() ?? 0 }
        return ([header] + lines).map { cells in
            cells.enumerated().map { column, cell in
                column == cells.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
