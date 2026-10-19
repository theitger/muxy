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
    You are working unattended: nobody will answer questions until this is done. Decide sensibly on your own and note your assumptions in the pull request. When the work is done and the checks pass, commit, push the branch and open the pull request yourself.
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
        var babysits = 0
        /// A plan first, the work after your go-ahead.
        var plan: Bool?
        var id: String { "\(issue.repo)#\(issue.number)" }
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
    private static let storeKey = "queue"
    private static let runningKey = "queueRunning"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        running = UserDefaults.standard.bool(forKey: Self.runningKey) && items.contains { !$0.phase.isFinished }
    }

    /// After launch: an interrupted run goes on.
    func resume() {
        if running { begin() }
    }

    var parallel: Int {
        let saved = UserDefaults.standard.integer(forKey: Self.parallelKey)
        return saved > 0 ? saved : Self.defaultParallel
    }

    func contains(_ issue: Issue) -> Bool {
        items.contains { $0.issue.number == issue.number && $0.issue.repo.lowercased() == issue.repo.lowercased() }
    }

    func add(_ issue: Issue, agent: AgentKind, plan: Bool = false) {
        guard !contains(issue) else { return }
        var item = Item(issue: issue, agent: agent)
        item.plan = plan ? true : nil
        items.append(item)
        save()
        if running { tick() }
    }

    func remove(_ item: Item) {
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
        save()
        begin()
    }

    func clearFinished() {
        items.removeAll { $0.phase.isFinished }
        save()
    }

    func start() {
        guard items.contains(where: { $0.phase == .queued }) else { return }
        running = true
        save()
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
        guard HubModel.shared.updated != nil else { return }
        let now = Date()
        for index in items.indices where items[index].phase.isActive {
            advance(&items[index], now: now)
        }
        // An agent whose plan is (nearly) used up gets nothing new until it frees.
        held = nil
        while running, items.filter({ $0.phase.isActive }).count < parallel,
              let next = items.firstIndex(where: { $0.phase == .queued && Usage.shared.exhausted($0.agent) == nil }) {
            launch(&items[next], now: now)
        }
        if running, let waiting = items.first(where: { $0.phase == .queued }),
           let window = Usage.shared.exhausted(waiting.agent) {
            held = window.resets.map { L("%@'s limit is used up until %@", waiting.agent.name, $0.formatted(date: .omitted, time: .shortened)) }
                ?? L("%@'s limit is used up", waiting.agent.name)
        }
        if !items.contains(where: { $0.phase == .queued }) { running = false }
        // Plans waiting for you: approved in the session too, they go on.
        for index in items.indices where items[index].phase == .planReady {
            guard let workspace = HubModel.shared.session(for: items[index].issue) else { continue }
            if !workspace.sessions.contains(where: \.planning) {
                items[index].phase = .running
                items[index].acted = now
                items[index].idleSince = nil
            }
        }
        if !running, !items.contains(where: { $0.phase.isActive || $0.phase == .planReady }) { end() }
        save()
    }

    private func launch(_ item: inout Item, now: Date) {
        guard let window = Store.shared.activeWindow ?? Store.shared.windows.first else { return }
        guard HubModel.shared.checkout(of: item.issue.repo) != nil else {
            item.phase = .failed(L("%@ isn't cloned on this Mac", item.issue.repo))
            return
        }
        item.phase = .running
        item.started = now
        item.acted = now
        HubModel.shared.start(item.issue, agents: [item.agent], in: window, hideHub: false, unattended: true,
                              plan: item.plan == true)
    }

    private func advance(_ item: inout Item, now: Date) {
        guard let workspace = HubModel.shared.session(for: item.issue) else {
            // Launching takes a moment (the worktree, its setup).
            if item.sawWork {
                item.phase = .needsYou(L("Its session was closed."))
            } else if item.started.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                item.phase = .failed(L("The session didn't start."))
            }
            return
        }
        // Its worktree is still being made: the folder (and so the branch
        // and its PR) isn't the session's own yet.
        guard !workspace.sessions.contains(where: { $0.preparing != nil }) else { return }
        if workspace.agent == .working {
            item.sawWork = true
            item.idleSince = nil
        } else if item.sawWork, workspace.agent == .idle, item.idleSince == nil {
            item.idleSince = now
        }
        let facts = Facts(
            step: Flow.next(for: workspace), agent: workspace.agent, idleSince: item.idleSince,
            hasPR: workspace.context.pr != nil, quorumInstalled: Quorum.isInstalled,
            merged: workspace.context.pr != nil && workspace.context.prState != .open
        )
        let decision = Self.decide(item, facts: facts, now: now)
        switch decision {
        case .wait:
            break
        case let .finish(phase):
            item.phase = phase
        case .askForPR:
            item.askedForPR = true
            item.acted = now
            if let window = Store.shared.window(of: workspace) {
                Flow.take(.openPR, in: workspace, window: window)
            }
        case .babysit:
            item.babysits += 1
            item.acted = now
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
    /// quorum's fix loop gets two chances, then it's yours.
    nonisolated static let maxBabysits = 2

    nonisolated static func decide(_ item: Item, facts: Facts, now: Date) -> Decision {
        if facts.merged { return .finish(.ready) }
        if let started = item.started, now.timeIntervalSince(started) > maxRun {
            return .finish(.needsYou(L("Still not done after %d hours.", Int(maxRun / 3600))))
        }
        if facts.agent == .failed { return .finish(.needsYou(L("The agent stopped on an error."))) }
        let settled = item.acted.map { now.timeIntervalSince($0) > settle } ?? true
        switch facts.step {
        case .approvePlan:
            return .finish(.planReady)
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
            return facts.quorumInstalled ? .babysit : .finish(.ready)
        case let .fix(why):
            guard settled else { return .wait }
            return item.babysits < maxBabysits && facts.quorumInstalled ? .babysit : .finish(.needsYou(why))
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

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
        UserDefaults.standard.set(running, forKey: Self.runningKey)
    }
}
