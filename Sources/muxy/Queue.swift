import Foundation

/// Issues you put in line to be worked on while you are away: a few at a
/// time, each in its own worktree, without permission prompts, from the
/// agent's work through muxy's checks, the pull request and quorum's fix
/// loop, up to ready to land. Landing stays your click. It starts when
/// you press Start and stops starting new ones when you press Stop.
@MainActor
final class Queue: ObservableObject {
    static let shared = Queue()

    static let parallelKey = "queueParallel"
    static let defaultParallel = 3

    /// Appended to the issue prompt: nobody answers until it is done.
    nonisolated static let unattendedNote = """
    You are working unattended: nobody will answer questions until this is done. Decide sensibly on your own and note your assumptions in the pull request. When the work is done and the checks pass, commit, push the branch and open the pull request yourself, with "Closes" and the issue in its description.
    """

    struct Item: Codable, Equatable, Identifiable {
        var issue: Issue
        var agent: AgentKind
        var phase: Phase = .queued
        /// When muxy last did something for it (started it, asked for the
        /// PR, handed it to quorum): the next look waits a little.
        var acted: Date?
        var started: Date?
        /// The agent was seen at work: idle afterwards means its turn ended.
        var sawWork = false
        /// Since when the agent rests after working.
        var idleSince: Date?
        var askedForPR = false
        /// Kept so older queue files retain their conservative shared budget.
        var babysits = 0
        /// Optional to decode queue files written before reviews and repairs
        /// had independent budgets.
        var reviews: Int?
        var repairs: Int?
        /// A plan first, the work after your go-ahead.
        var plan: Bool?
        var dependencies: [String]?
        var limits: AutomationLimits?
        var awaitingAgent: Bool?
        var awaitedTurns: Int?
        var id: String { "\(issue.repo)#\(issue.number)" }

        var reviewCount: Int { reviews ?? babysits }
        var repairCount: Int { repairs ?? babysits }
    }

    enum Phase: Codable, Equatable {
        case queued
        /// Launched, the agent builds (or quorum works on its PR).
        case running
        /// Done: ready to land.
        case ready
        /// Stopped on something only you can do; the words say what.
        case needsYou(String)
        case failed(String)
        /// Its plan waits for your go-ahead; it holds no slot meanwhile.
        case planReady

        var isActive: Bool { self == .running }
        var isFinished: Bool {
            switch self {
            case .ready, .needsYou, .failed: true
            case .queued, .running, .planReady: false
            }
        }
    }

    @Published private(set) var items: [Item] = []
    /// Started and not stopped: queued items start as slots free up.
    @Published private(set) var running = false
    /// Why queued items wait although a slot is free: a used-up limit.
    @Published private(set) var held: String?

    private var timer: Timer?
    private struct Saved: Codable {
        var items: [Item]
        var running: Bool
        var merged: Set<String>?
    }
    private let file: URL
    /// A queue we could not decode must never be replaced with an empty one.
    private var canSave = true
    @Published private(set) var problem: String?
    @Published private(set) var merged: Set<String> = []

    init(file: URL = URL(fileURLWithPath: StateDirectory.path + "/queue.json"), restoreLegacy: Bool = Paths.isApp) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
                guard Set(saved.items.map(\.id)).count == saved.items.count else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Duplicate queue task identifiers"))
                }
                items = saved.items
                running = saved.running && items.contains { !$0.phase.isFinished }
                merged = saved.merged ?? []
            } catch {
                canSave = false
                problem = L("The queue could not be restored: %@", error.localizedDescription)
            }
        } else if restoreLegacy, let data = UserDefaults.standard.data(forKey: "queue"),
                  let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
            running = UserDefaults.standard.bool(forKey: "queueRunning")
        }
    }

    /// Monitor active work even when new starts were paused before quitting.
    func resume() {
        if Self.shouldMonitor(running: running, items: items) { begin() }
    }

    nonisolated static func shouldMonitor(running: Bool, items: [Item]) -> Bool {
        running || items.contains(where: { $0.phase.isActive || $0.phase == .planReady })
    }

    var dependencyGraph: [String: [String]] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.dependencies ?? []) })
    }

    func configure(_ item: Item, dependencies: [String], limits: AutomationLimits) -> String? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return L("Task not found.") }
        guard !items[index].phase.isActive else { return L("Pause this task before changing its dependencies or limits.") }
        if let error = TaskDependencies.validate(id: item.id, dependencies: dependencies, graph: dependencyGraph) { return error }
        items[index].dependencies = Array(Set(dependencies)).sorted()
        items[index].limits = limits
        return save() ? nil : problem
    }

    func waiting(for item: Item) -> [String] {
        TaskDependencies.waiting(item.dependencies ?? [], merged: merged)
    }

    func reason(for item: Item) -> String? {
        let dependencies = waiting(for: item)
        if !dependencies.isEmpty { return L("Waiting for merge: %@", dependencies.joined(separator: ", ")) }
        if let limit = Usage.shared.exhausted(item.agent) {
            return limit.resets.map { L("Plan limit resets at %@", $0.formatted(date: .omitted, time: .shortened)) }
                ?? L("The agent's plan limit is used up.")
        }
        return nil
    }

    func item(for workspace: Workspace) -> Item? {
        let issues = workspace.sessions.compactMap(\.issue)
        return items.first { item in issues.contains { $0.repo.lowercased() == item.issue.repo.lowercased() && $0.number == item.issue.number } }
    }

    func landingBlocker(for workspace: Workspace) -> String? {
        guard let item = item(for: workspace), !waiting(for: item).isEmpty else { return nil }
        return reason(for: item)
    }

    func pause(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].phase = .needsYou(L("Automation paused."))
        guard save() else { return }
        if let workspace = HubModel.shared.session(for: item.issue) { Landing.shared.cancel(workspace) }
    }

    /// Explicit continuation starts a fresh budget, retaining the same checkout.
    func retry(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), !items[index].phase.isActive else { return }
        let existing = HubModel.shared.session(for: item.issue)
        let archived = WorkLedger.shared.items.values.first {
            $0.issue?.repo.lowercased() == item.issue.repo.lowercased() && $0.issue?.number == item.issue.number && $0.isOpen
        }
        if let root = existing?.context.root ?? archived?.root,
           let branch = existing?.context.branch ?? archived?.branch,
           !Landing.shared.allowRetry(root: root, branch: branch) { return }
        items[index].phase = existing != nil || archived != nil ? .running : .queued
        items[index].started = Date()
        items[index].acted = nil
        items[index].babysits = 0
        items[index].reviews = nil
        items[index].repairs = nil
        items[index].askedForPR = false
        items[index].awaitingAgent = nil
        items[index].awaitedTurns = nil
        items[index].idleSince = nil
        running = true
        guard save() else { return }
        if existing == nil, let archived, let window = Store.shared.activeWindow ?? Store.shared.windows.first {
            WorkLedger.shared.resume(archived, in: window)
        }
        begin()
    }

    /// A human decision hands the same task back to its existing workflow.
    /// Save this transition before delivering input; start observing afterwards.
    @discardableResult
    func followDecision(in workspace: Workspace, awaitingAgent: Bool) -> Bool {
        guard let queued = item(for: workspace), let index = items.firstIndex(where: { $0.id == queued.id }) else { return true }
        var savedItems = items
        savedItems[index] = Self.resumed(savedItems[index], awaitingAgent: awaitingAgent,
                                         turns: workspace.agentTab?.turnsEnded ?? 0, now: Date())
        guard save(Saved(items: savedItems, running: running, merged: merged)) else { return false }
        items = savedItems
        return true
    }

    nonisolated static func resumed(_ item: Item, awaitingAgent: Bool, turns: Int, now: Date) -> Item {
        var resumed = item
        resumed.phase = .running
        resumed.acted = now
        resumed.started = resumed.started ?? now
        resumed.idleSince = nil
        resumed.awaitingAgent = awaitingAgent
        resumed.awaitedTurns = turns
        return resumed
    }

    /// The request could not reach the terminal. Stop waiting for a turn
    /// that will not start, while leaving the caller's draft available to retry.
    func deliveryFailed(in workspace: Workspace, message: String) {
        guard let queued = item(for: workspace), let index = items.firstIndex(where: { $0.id == queued.id }) else { return }
        items[index] = Self.failedHandoff(items[index], message: message, now: Date())
        _ = save()
    }

    nonisolated static func failedHandoff(_ item: Item, message: String, now: Date) -> Item {
        var failed = item
        failed.phase = .needsYou(message)
        failed.acted = now
        failed.awaitingAgent = nil
        failed.awaitedTurns = nil
        return failed
    }

    enum Followup: Equatable { case waiting, started, unconfirmed }

    nonisolated static func followup(_ item: Item, agent: AgentState, turns: Int, now: Date) -> Followup {
        if agent == .working || turns > (item.awaitedTurns ?? 0) { return .started }
        return item.acted.map { now.timeIntervalSince($0) < settle } ?? false ? .waiting : .unconfirmed
    }

    private func recordMerges() {
        for item in items {
            if WorkLedger.shared.items.values.contains(where: { Self.recordsMerge($0, for: item) }) {
                merged.insert(item.id)
            }
        }
    }

    /// A reopened issue is a new queue run. Its predecessor's archived PR
    /// must not release it or any task that depends on it.
    nonisolated static func recordsMerge(_ work: WorkItem, for item: Item) -> Bool {
        guard let started = item.started, work.touched >= started else { return false }
        return work.issue?.repo.lowercased() == item.issue.repo.lowercased()
            && work.issue?.number == item.issue.number && work.prState == "merged"
    }

    var parallel: Int {
        let saved = UserDefaults.standard.integer(forKey: Self.parallelKey)
        return saved > 0 ? saved : Self.defaultParallel
    }

    func contains(_ issue: Issue) -> Bool {
        items.contains { $0.issue.number == issue.number && $0.issue.repo.lowercased() == issue.repo.lowercased() }
    }

    func add(_ issue: Issue, agent: AgentKind, plan: Bool = false) {
        guard issue.isOpen, !contains(issue) else { return }
        var item = Item(issue: issue, agent: agent)
        item.limits = TaskLedger.shared.record(for: TaskTarget(issue: issue)).limits
        item.plan = plan ? true : nil
        merged.remove(item.id)
        items.append(item)
        save()
        if running { tick() }
    }

    func remove(_ item: Item) {
        guard !item.phase.isActive,
              !items.contains(where: { ($0.dependencies ?? []).contains(item.id) && !merged.contains($0.id) }) else { return }
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Your go-ahead for a plan, from the queue's list.
    func approve(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              let workspace = HubModel.shared.session(for: item.issue),
              let planner = workspace.sessions.first(where: \.planning),
              Flow.approvePlan(in: planner) else { return }
        items[index].phase = .running
        items[index].acted = Date()
        items[index].idleSince = nil
        items[index].started = Date()
        items[index].awaitingAgent = true
        items[index].awaitedTurns = workspace.agentTab?.turnsEnded ?? 0
        save()
        begin()
    }

    func clearFinished() {
        let required = Set(items.flatMap { $0.dependencies ?? [] }).subtracting(merged)
        items.removeAll { $0.phase.isFinished && !required.contains($0.id) }
        save()
    }

    func start() {
        guard items.contains(where: { $0.phase == .queued }) else { return }
        running = true
        guard save() else { return }
        begin()
    }

    /// No new starts; what runs finishes.
    func stop() {
        running = false
        save()
        if !items.contains(where: { $0.phase.isActive }) { end() }
    }

    private func begin() {
        StayAwake.shared.forQueue = true
        if timer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                MainActor.assumeIsolated { Queue.shared.tick() }
            }
            timer.tolerance = 3
            self.timer = timer
        }
        tick()
    }

    private func end() {
        timer?.invalidate()
        timer = nil
        StayAwake.shared.forQueue = false
    }

    // MARK: Driving

    func tick() {
        // Right after launch: sessions are coming back and the hub doesn't
        // know the checkouts yet, so nothing would be found.
        guard HubModel.shared.updated != nil, problem == nil else { return }
        recordMerges()
        let now = Date()
        for index in items.indices where items[index].phase.isActive {
            advance(at: index, now: now)
        }
        // An agent whose plan is (nearly) used up gets nothing new until it frees.
        held = nil
        while running, items.filter({ $0.phase.isActive }).count < parallel,
              let next = items.firstIndex(where: { $0.phase == .queued && waiting(for: $0).isEmpty && Usage.shared.exhausted($0.agent) == nil }) {
            guard launch(at: next, now: now) else { break }
        }
        if running, let waiting = items.first(where: { $0.phase == .queued }),
           let window = Usage.shared.exhausted(waiting.agent) {
            held = window.resets.map { L("%@'s limit is used up until %@", waiting.agent.name, $0.formatted(date: .omitted, time: .shortened)) }
                ?? L("%@'s limit is used up", waiting.agent.name)
        }
        if running, held == nil, let waiting = items.first(where: { $0.phase == .queued }) { held = reason(for: waiting) }
        if !items.contains(where: { $0.phase == .queued }) { running = false }
        // Plans waiting for you: approved in the session too, they go on.
        for index in items.indices where items[index].phase == .planReady {
            guard let workspace = HubModel.shared.session(for: items[index].issue) else { continue }
            if !workspace.sessions.contains(where: \.planning) {
                items[index].phase = .running
                items[index].acted = now
                items[index].started = now
                items[index].idleSince = nil
            }
        }
        if !running, !items.contains(where: { $0.phase.isActive || $0.phase == .planReady }) { end() }
        save()
    }

    @discardableResult
    private func launch(at index: Int, now: Date) -> Bool {
        guard let window = Store.shared.activeWindow ?? Store.shared.windows.first else { return false }
        var item = items[index]
        if HubModel.shared.session(for: item.issue) != nil {
            item.phase = .running
            item.started = item.started ?? now
            items[index] = item
            return save()
        }
        // A launch intent was saved, but its session disappeared across a crash.
        // It must be inspected before starting another agent for the same issue.
        if item.acted != nil {
            item.phase = .needsYou(L("The previous launch could not be confirmed. Inspect the task before retrying."))
            items[index] = item
            return save()
        }
        guard HubModel.shared.checkout(of: item.issue.repo) != nil else {
            items[index].phase = .failed(L("%@ isn't cloned on this Mac", item.issue.repo))
            return save()
        }
        item.phase = .running
        item.started = now
        item.acted = now
        items[index] = item
        guard save() else { return false }
        HubModel.shared.start(item.issue, agents: [item.agent], in: window, hideHub: false, unattended: true,
                              plan: item.plan == true) { [weak self] id in
            guard id == nil, let self, let index = self.items.firstIndex(where: { $0.id == item.id }),
                  self.items[index].started == now, self.items[index].phase == .running else { return }
            self.items[index].phase = .needsYou(L("The task could not start. Inspect its checkout and base, then retry."))
            self.save()
        }
        return true
    }

    private func advance(at index: Int, now: Date) {
        var item = items[index]
        defer { items[index] = item }
        guard let workspace = HubModel.shared.session(for: item.issue) else {
            // Launching takes a moment (the worktree, its setup).
            if item.sawWork {
                item.phase = .needsYou(L("Its session was closed."))
            } else if item.started.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                item.phase = .failed(L("The session didn't start."))
            }
            return
        }
        if Landing.shared.requiresInspection(workspace) {
            item.phase = .needsYou(L("The previous operation needs inspection before continuing."))
            return
        }
        // Its worktree is still being made: the folder (and so the branch
        // and its PR) isn't the session's own yet.
        guard !workspace.sessions.contains(where: { $0.preparing != nil }) else { return }
        if workspace.context.pr != nil, workspace.context.prState == .merged {
            item.phase = .ready
            return
        }
        if item.awaitingAgent == true {
            switch Self.followup(item, agent: workspace.agent, turns: workspace.agentTab?.turnsEnded ?? 0, now: now) {
            case .waiting: return
            case .unconfirmed:
                item.phase = .needsYou(L("The agent did not confirm the follow-up. Inspect the conversation before sending it again."))
                return
            case .started:
                item.awaitingAgent = nil
                item.sawWork = true
            }
        }
        if workspace.agent == .working {
            item.sawWork = true
            item.idleSince = nil
        } else if item.sawWork, workspace.agent == .idle, item.idleSince == nil {
            item.idleSince = now
        }
        // Limits pause further requests, but the task's own clock still runs.
        let timedOut = item.started.map { now.timeIntervalSince($0) > (item.limits ?? AutomationLimits()).seconds } ?? false
        if Usage.shared.exhausted(item.agent) != nil, !timedOut { return }
        let facts = Facts(
            step: Flow.next(for: workspace), agent: workspace.agent, idleSince: item.idleSince,
            hasPR: workspace.context.pr != nil, quorumInstalled: Quorum.isInstalled,
            merged: workspace.context.pr != nil && workspace.context.prState == .merged,
            closed: workspace.context.pr != nil && workspace.context.prState == .closed
        )
        let decision = Self.decide(item, facts: facts, now: now)
        switch decision {
        case .wait:
            break
        case let .finish(phase):
            item.phase = phase
            if case .needsYou = phase, let started = item.started,
               now.timeIntervalSince(started) > (item.limits ?? AutomationLimits()).seconds {
                items[index] = item
                guard save() else { return }
                Landing.shared.cancel(workspace)
                if let agent = workspace.agentTab, agent.agent == .working {
                    _ = RemoteState.press("ctrl-c", in: agent)
                }
            }
        case .askForPR:
            item.askedForPR = true
            item.acted = now
            items[index] = item
            guard save() else { return }
            guard let window = Store.shared.window(of: workspace),
                  Flow.take(.openPR, in: workspace, window: window) else {
                items[index] = Self.failedHandoff(item, message: L("The request to open the pull request could not be delivered. Check the terminal and retry."), now: now)
                _ = save()
                return
            }
        case .babysit:
            switch facts.step {
            case .review: item.reviews = item.reviewCount + 1
            case .fix: item.repairs = item.repairCount + 1
            default: break
            }
            item.acted = now
            items[index] = item
            guard save() else { return }
            // The same way as the hub's step: the branch made ready, then quorum.
            Landing.shared.review(workspace)
        }
    }

    // MARK: Deciding (pure, for the tests)

    struct Facts {
        var step: NextStep
        var agent: AgentState
        /// Resting since then after having worked: its turn ended.
        var idleSince: Date?
        var hasPR: Bool
        var quorumInstalled: Bool
        var merged: Bool
        var closed = false
    }

    enum Decision: Equatable {
        case wait
        case finish(Phase)
        case askForPR
        case babysit
    }

    /// Seconds after muxy acted before it looks again: quorum and the
    /// agent need a moment before their state shows.
    nonisolated static let settle: TimeInterval = 90
    /// However long agent and quorum take, after this it's yours.
    nonisolated static let maxRun: TimeInterval = 8 * 3600
    nonisolated static func decide(_ item: Item, facts: Facts, now: Date) -> Decision {
        if facts.merged { return .finish(.ready) }
        if facts.closed { return .finish(.needsYou(L("The pull request was closed without merging."))) }
        if let started = item.started, now.timeIntervalSince(started) > (item.limits ?? AutomationLimits()).seconds {
            return .finish(.needsYou(L("Still not done after %d hours.", Int((item.limits ?? AutomationLimits()).seconds / 3600))))
        }
        if facts.agent == .failed { return .finish(.needsYou(L("The agent stopped on an error."))) }
        let settled = item.acted.map { now.timeIntervalSince($0) > settle } ?? true
        switch facts.step {
        case .approvePlan:
            return .finish(.planReady)
        case .accept:
            return .finish(.needsYou(L("Inspect and accept the implementation.")))
        case .answer:
            return .finish(.needsYou(L("The agent asks you something.")))
        case .land, .landing:
            return .finish(.ready)
        case .reviewing:
            return .wait
        case .openPR:
            guard settled else { return .wait }
            // Asked once and still no PR after a while: it's yours.
            return item.askedForPR ? .finish(.needsYou(L("No pull request was opened."))) : .askForPR
        case .review:
            guard settled else { return .wait }
            return facts.quorumInstalled && item.reviewCount < (item.limits ?? AutomationLimits()).reviewAttempts
                ? .babysit : facts.quorumInstalled ? .finish(.needsYou(L("Review attempt limit reached."))) : .finish(.ready)
        case let .fix(why):
            guard settled else { return .wait }
            return item.repairCount < (item.limits ?? AutomationLimits()).repairAttempts && facts.quorumInstalled ? .babysit : .finish(.needsYou(why))
        case .wait:
            // The turn ended a while ago without anything to show for it
            // (a PR, which quorum or CI may be busy with, is something).
            if !facts.hasPR, facts.agent == .idle, let idle = facts.idleSince, now.timeIntervalSince(idle) > settle {
                return .finish(.needsYou(L("The agent stopped without changes.")))
            }
            return .wait
        case .none:
            return settled && facts.idleSince != nil ? .finish(.needsYou(L("Nothing to do: no changes."))) : .wait
        }
    }

    @discardableResult
    private func save(_ saved: Saved? = nil) -> Bool {
        guard canSave else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved ?? Saved(items: items, running: running, merged: merged)).write(to: file, options: .atomic)
            problem = nil
            return true
        } catch {
            problem = L("The queue could not be saved: %@", error.localizedDescription)
            return false
        }
    }
}
