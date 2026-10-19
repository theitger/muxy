import Foundation

/// "Land": takes a session's pull request the rest of the way, one step
/// after the other, and hands back to its agent wherever a step needs
/// thought: uncommitted work, a conflict with the base, a failing check.
/// When the agent's next turn ends, landing goes on by itself.
///
///  1. everything committed (else: the agent commits)
///  2. up to date with the base: merged in when that is clean (else: the
///     agent merges and resolves)
///  3. muxy's own checks pass (else: the agent gets the failures)
///  4. pushed
///  5. quorum's review loop, when it is installed and you want it
///  6. GitHub merges it once it may (auto-merge), or muxy does when checks
///     are green and auto-merge is off for the repository
///
/// "Review and fix with quorum" takes the same way and stops after 5:
/// quorum's babysit refuses uncommitted or unpushed work, so the branch
/// is made ready for it first. What quorum does itself (conflicts with
/// RESOLVE_CONFLICTS, merging with AUTO_MERGE) is left to it.
@MainActor
final class Landing: ObservableObject {
    static let shared = Landing()

    enum Step: Equatable {
        case preparing(String)
        /// The agent was asked to do something; landing resumes after its turn.
        case waitingForAgent(String)
        case proving
        case pushing
        case reviewing
        /// quorum is done and the goal was its review: nothing merges.
        case reviewed
        /// Handed to GitHub: merges when checks and rules allow.
        case merging(String)
        case landed
        case failed(String)

        var isActive: Bool {
            switch self {
            case .landed, .reviewed, .failed: false
            default: true
            }
        }

        var text: String {
            switch self {
            case let .preparing(text): text
            case let .waitingForAgent(text): text
            case .proving: L("Running the checks")
            case .pushing: L("Pushing")
            case .reviewing: L("quorum reviews and fixes")
            case .reviewed: L("quorum is done")
            case let .merging(text): text
            case .landed: L("Merged")
            case let .failed(text): text
            }
        }
    }

    /// Run quorum's review loop between pushing and merging.
    static let quorumKey = "landWithQuorum"
    var withQuorum: Bool {
        (UserDefaults.standard.object(forKey: Self.quorumKey) as? Bool ?? true) && Quorum.isInstalled
    }

    /// Where a run ends: merged, or quorum's review and fixes.
    enum Goal { case land, review }

    @Published private(set) var steps: [Workspace.ID: Step] = [:]
    private(set) var goals: [Workspace.ID: Goal] = [:]
    /// Each landing's number: a step that finishes after a cancel or a new
    /// landing finds its number gone and does nothing.
    private var runs: [Workspace.ID: Int] = [:]
    /// Since when the current step waits: waiting never goes on forever.
    private var stepSince: [Workspace.ID: Date] = [:]
    /// When quorum was asked, so an older run's verdict doesn't count.
    private var quorumSince: [Workspace.ID: Date] = [:]
    private var timer: Timer?
    /// The agent asked for something this many times in one landing: then
    /// it is your call, not another loop.
    private var asks: [Workspace.ID: Int] = [:]
    /// The head that was pushed after the checks passed.
    private var proven: [Workspace.ID: String?] = [:]

    func step(for workspace: Workspace) -> Step? { steps[workspace.id] }

    func canLand(_ workspace: Workspace) -> Bool {
        workspace.context.pr != nil && workspace.context.prState == .open && workspace.context.checkout != nil
    }

    func land(_ workspace: Workspace) {
        begin(workspace, goal: .land)
    }

    /// The branch made ready for quorum (committed, pushed, quorum's fixes
    /// taken in), then quorum's babysit; it stops there.
    func review(_ workspace: Workspace) {
        begin(workspace, goal: .review)
    }

    func goal(for workspace: Workspace) -> Goal { goals[workspace.id] ?? .land }

    private func begin(_ workspace: Workspace, goal: Goal) {
        // One run per session at a time.
        guard canLand(workspace), steps[workspace.id]?.isActive != true else { return }
        goals[workspace.id] = goal
        runs[workspace.id, default: 0] += 1
        asks[workspace.id] = 0
        advance(workspace)
        startTimer()
    }

    func cancel(_ workspace: Workspace) {
        runs[workspace.id, default: 0] += 1
        steps[workspace.id] = nil
        quorumSince[workspace.id] = nil
    }

    /// The agent's turn ended: a landing waiting on it goes on.
    func turnEnded(in workspace: Workspace) {
        guard case .waitingForAgent = steps[workspace.id] else { return }
        let run = runs[workspace.id]
        // Give the push that often ends a turn a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard self.runs[workspace.id] == run, case .waitingForAgent = self.steps[workspace.id] else { return }
            self.advance(workspace)
        }
    }

    private func set(_ step: Step, for workspace: Workspace) {
        if steps[workspace.id] != step { stepSince[workspace.id] = Date() }
        steps[workspace.id] = step
    }

    /// Still the landing that started this step, not cancelled meanwhile.
    private func current(_ workspace: Workspace, _ run: Int?) -> Bool {
        runs[workspace.id] == run && steps[workspace.id]?.isActive == true
    }

    /// quorum works on this run: the review goal, or landing with it.
    private func usesQuorum(_ workspace: Workspace) -> Bool {
        goal(for: workspace) == .review ? Quorum.isInstalled : withQuorum
    }

    // MARK: Steps

    private func advance(_ workspace: Workspace) {
        guard let checkout = workspace.context.checkout, let root = workspace.context.root,
              let pr = workspace.context.pr else { return }
        let run = runs[workspace.id]
        if workspace.sessions.contains(where: { $0.agent == .working }) {
            set(.waitingForAgent(L("Waiting for the agent's turn to end")), for: workspace)
            return
        }
        // Typing now would answer the agent's open question.
        if workspace.sessions.contains(where: { $0.agent == .blocked }) {
            set(.failed(L("The agent asks you something: answer it, then land again")), for: workspace)
            return
        }
        set(.preparing(L("Looking at the branch")), for: workspace)
        Task.detached(priority: .userInitiated) {
            let state = Self.inspect(checkout: checkout, root: root)
            await MainActor.run {
                guard self.current(workspace, run) else { return }
                self.act(on: state, workspace: workspace, checkout: checkout, root: root, pr: pr)
            }
        }
    }

    /// Where the branch stands, before anything is changed. Blocking.
    nonisolated static func inspect(checkout: String, root: String) -> Inspection {
        let git = WorkState.git
        let dirty = !(Shell.run(git, ["status", "--porcelain"], in: checkout) ?? "").isEmpty
        let start = Launcher.startPoint(in: root, recipe: WorktreeRecipe.load(root: root))
        if start.hasPrefix("origin/") {
            _ = Shell.execute(git, ["fetch", "--quiet", "origin", String(start.dropFirst("origin/".count))], in: root, timeout: 60)
        }
        let behind = Shell.execute(git, ["merge-base", "--is-ancestor", start, "HEAD"], in: checkout).status != 0
        let conflicts = behind ? WorkState.conflicts(between: "HEAD", and: start, in: checkout) ?? [] : []
        let unpushed = Shell.run(git, ["rev-list", "--count", "@{push}..HEAD"], in: checkout).flatMap(Int.init)
        // What origin has of the branch that this checkout doesn't: quorum
        // pushes its fixes there.
        var fromOrigin = 0
        if let branch = Shell.run(git, ["branch", "--show-current"], in: checkout), !branch.isEmpty,
           Shell.execute(git, ["fetch", "--quiet", "origin", branch], in: checkout, timeout: 60).status == 0 {
            fromOrigin = Shell.run(git, ["rev-list", "--count", "HEAD..FETCH_HEAD"], in: checkout).flatMap(Int.init) ?? 0
        }
        return Inspection(dirty: dirty, start: start, behind: behind, conflicts: conflicts, unpushed: unpushed ?? 1,
                          fromOrigin: fromOrigin)
    }

    struct Inspection {
        var dirty: Bool
        var start: String
        var behind: Bool
        var conflicts: [String]
        /// Commits origin doesn't have (1 when there is no upstream yet).
        var unpushed: Int
        /// Commits origin's branch has that this checkout doesn't.
        var fromOrigin = 0
    }

    private func act(on state: Inspection, workspace: Workspace, checkout: String, root: String, pr: Int) {
        let run = runs[workspace.id]
        if state.dirty {
            ask(workspace, L("The agent commits its remaining changes"),
                "Commit all remaining changes in this checkout with a clear message, then push the branch. Don't change anything else.")
            return
        }
        // quorum pushed fixes: taken in first, or the push below is refused.
        if state.fromOrigin > 0 {
            set(.preparing(L("Taking in quorum's fixes")), for: workspace)
            Task.detached(priority: .userInitiated) {
                let git = WorkState.git
                var taken = Shell.execute(git, ["merge", "--ff-only", "--quiet", "FETCH_HEAD"], in: checkout, timeout: 120).status == 0
                if !taken {
                    // Both moved: merged when that is clean.
                    taken = Shell.execute(git, ["merge", "--no-edit", "--quiet", "FETCH_HEAD"], in: checkout, timeout: 300).status == 0
                    if !taken { _ = Shell.execute(git, ["merge", "--abort"], in: checkout) }
                }
                let again = Self.inspect(checkout: checkout, root: root)
                let done = taken
                await MainActor.run {
                    guard self.current(workspace, run) else { return }
                    if done {
                        self.act(on: again, workspace: workspace, checkout: checkout, root: root, pr: pr)
                    } else {
                        self.ask(workspace, L("The agent merges quorum's fixes"),
                                 "The branch on origin has commits this checkout doesn't (quorum's fixes). Pull them in (git pull --no-rebase origin HEAD), resolve anything that comes up, run the relevant tests, commit and push.")
                    }
                }
            }
            return
        }
        // quorum brings the branch up to date itself (RESOLVE_CONFLICTS).
        if usesQuorum(workspace), QuorumBehavior.current.resolvesConflicts {
            prove(workspace, checkout: checkout, root: root, pr: pr)
            return
        }
        if state.behind, !state.conflicts.isEmpty {
            let files = state.conflicts.prefix(20).map { "- \($0)" }.joined(separator: "\n")
            ask(workspace, L("The agent resolves conflicts with %@", state.start),
                "Merge \(state.start) into this branch (git fetch first). These files conflict:\n\(files)\n\nResolve each conflict keeping both sides' intent, run the relevant tests, commit the merge and push.")
            return
        }
        if state.behind {
            set(.preparing(L("Merging %@ in", state.start)), for: workspace)
            Task.detached(priority: .userInitiated) {
                let merged = Shell.execute(WorkState.git, ["merge", "--no-edit", "--quiet", state.start], in: checkout, timeout: 300)
                if merged.status != 0 {
                    _ = Shell.execute(WorkState.git, ["merge", "--abort"], in: checkout)
                }
                await MainActor.run {
                    guard self.current(workspace, run) else { return }
                    if merged.status == 0 {
                        self.prove(workspace, checkout: checkout, root: root, pr: pr)
                    } else {
                        self.ask(workspace, L("The agent merges %@", state.start),
                                 "Merge \(state.start) into this branch, resolve anything that comes up, run the relevant tests, commit and push.")
                    }
                }
            }
            return
        }
        prove(workspace, checkout: checkout, root: root, pr: pr)
    }

    private func prove(_ workspace: Workspace, checkout: String, root: String, pr: Int) {
        let run = runs[workspace.id]
        set(.proving, for: workspace)
        Task.detached(priority: .userInitiated) {
            let checks = ProofCheck.load(root: root)
            await MainActor.run {
                guard self.current(workspace, run) else { return }
                guard !checks.isEmpty else {
                    self.push(workspace, checkout: checkout, pr: pr)
                    return
                }
                // Every check, on the files as they are now: never a run
                // that started before (auto checks only, or before the merge).
                Proofs.shared.run(checkout: checkout, root: root, checks: checks, fresh: true) { [weak self] result in
                    guard let self, self.current(workspace, run), self.steps[workspace.id] == .proving else { return }
                    guard let result else {
                        self.set(.failed(L("The checks couldn't run")), for: workspace)
                        return
                    }
                    switch result.verdict {
                    case .failed:
                        guard let session = self.agent(of: workspace) else {
                            self.set(.failed(L("Checks failed")), for: workspace)
                            return
                        }
                        guard self.mayAsk(workspace) else { return }
                        Proofs.sendFailures(result, to: session)
                        self.set(.waitingForAgent(L("The agent fixes the failed checks")), for: workspace)
                    case .cancelled:
                        self.set(.failed(L("Checks cancelled")), for: workspace)
                    case .passed, .skipped:
                        self.push(workspace, checkout: checkout, pr: pr)
                    }
                }
            }
        }
    }

    private func push(_ workspace: Workspace, checkout: String, pr: Int) {
        let run = runs[workspace.id]
        set(.pushing, for: workspace)
        let reviewed = QuorumWatch.shared.status(for: workspace)?.succeeded == true
        Task.detached(priority: .userInitiated) {
            // Anything origin doesn't have yet? Without, quorum's last clean
            // review still holds and isn't repeated.
            let unpushed = Shell.run(WorkState.git, ["rev-list", "--count", "@{push}..HEAD"], in: checkout).flatMap(Int.init) ?? 1
            let result = Shell.execute(WorkState.git, ["push", "--quiet", "origin", "HEAD"], in: checkout, timeout: 1200)
            let head = Shell.run(WorkState.git, ["rev-parse", "HEAD"], in: checkout)
            await MainActor.run {
                guard self.current(workspace, run), self.steps[workspace.id] == .pushing else { return }
                self.proven[workspace.id] = head
                guard result.status == 0 else {
                    let reason = result.error.split(separator: "\n").last.map(String.init) ?? ""
                    self.set(.failed(L("Push failed: %@", reason)), for: workspace)
                    return
                }
                // The review goal always asks quorum; landing only when
                // quorum hasn't passed exactly what is on origin now.
                let review = self.goal(for: workspace) == .review
                if review || (self.withQuorum && !(reviewed && unpushed == 0)) {
                    self.quorumSince[workspace.id] = Date()
                    self.set(.reviewing, for: workspace)
                    QuorumWatch.shared.start(.babysit, in: workspace)
                } else {
                    self.merge(workspace, checkout: checkout, pr: pr)
                }
            }
        }
    }

    private func merge(_ workspace: Workspace, checkout: String, pr: Int) {
        let run = runs[workspace.id]
        // Pushed after the checks (quorum's fixes): only that head merges,
        // and only quorum's review vouches for it.
        let head = proven[workspace.id] ?? nil
        set(.merging(L("Handing it to GitHub")), for: workspace)
        Task.detached(priority: .userInitiated) {
            let outcome = Self.enableMerge(pr: pr, head: head, in: checkout)
            await MainActor.run {
                guard self.current(workspace, run), case .merging = self.steps[workspace.id] else { return }
                switch outcome {
                case let .armed(text): self.set(.merging(text), for: workspace)
                case .merged: self.set(.landed, for: workspace)
                case let .failed(text): self.set(.failed(text), for: workspace)
                }
                workspace.primary?.refreshContext()
            }
        }
    }

    enum MergeOutcome {
        case armed(String)
        case merged
        case failed(String)
    }

    /// `gh pr merge --auto` with the repository's own default method, for
    /// exactly the head that was proven (when known). Where auto-merge is
    /// off, a direct merge, but only once every CI check on the PR passed.
    nonisolated static func enableMerge(pr: Int, head: String?, in checkout: String) -> MergeOutcome {
        guard let gh = Shell.find("gh") else { return .failed(L("gh is not installed.")) }
        let view = Shell.execute(gh, ["repo", "view", "--json", "viewerDefaultMergeMethod"], in: checkout, timeout: 30)
        let method = (try? JSONSerialization.jsonObject(with: Data(view.output.utf8)) as? [String: Any])?["viewerDefaultMergeMethod"] as? String
        let flag = switch method {
        case "SQUASH": "--squash"
        case "REBASE": "--rebase"
        default: "--merge"
        }
        let match = head.map { ["--match-head-commit", $0] } ?? []
        let auto = Shell.execute(gh, ["pr", "merge", String(pr), "--auto", flag] + match, in: checkout, timeout: 60)
        if auto.status == 0 { return .armed(L("Merges when GitHub allows it")) }
        let view2 = Shell.execute(gh, ["pr", "view", String(pr), "--json", "statusCheckRollup"], in: checkout, timeout: 30)
        let rollup = (try? JSONSerialization.jsonObject(with: Data(view2.output.utf8)) as? [String: Any])?["statusCheckRollup"] as? [[String: Any]]
        guard let rollup, Git.checks(from: rollup) == .passed else {
            let reason = auto.error.split(separator: "\n").first.map(String.init) ?? ""
            return .failed(L("Auto-merge is off and CI isn't green yet: %@", reason))
        }
        let direct = Shell.execute(gh, ["pr", "merge", String(pr), flag] + match, in: checkout, timeout: 60)
        if direct.status == 0 { return .merged }
        let reason = (direct.error.isEmpty ? auto.error : direct.error).split(separator: "\n").first.map(String.init) ?? ""
        return .failed(L("GitHub won't merge yet: %@", reason))
    }

    // MARK: Waiting

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 3
        self.timer = timer
    }

    /// Steps that wait on others: quorum's verdict, GitHub's merge.
    private func tick() {
        for workspace in Store.shared.workspaces {
            guard let step = steps[workspace.id] else { continue }
            let context = workspace.context
            if context.prState == .merged {
                set(.landed, for: workspace)
                continue
            }
            if context.prState == .closed, step.isActive {
                set(.failed(L("The pull request was closed")), for: workspace)
                continue
            }
            // Nothing waits forever: a day for GitHub (reviews take time),
            // three hours for anything else.
            let waited = Date().timeIntervalSince(stepSince[workspace.id] ?? Date())
            let limit: TimeInterval = if case .merging = step { 86400 } else { 3 * 3600 }
            if step.isActive, waited > limit {
                set(.failed(L("Gave up waiting: land again")), for: workspace)
                continue
            }
            switch step {
            case .reviewing:
                guard let status = QuorumWatch.shared.status(for: workspace), !status.running,
                      status.date > (quorumSince[workspace.id] ?? .distantFuture).addingTimeInterval(-5)
                else { continue }
                if status.succeeded, let checkout = context.checkout, let pr = context.pr {
                    Self.takeFixes(in: checkout)
                    if goal(for: workspace) == .review || QuorumBehavior.current.merges {
                        // Done, or quorum merges it itself (AUTO_MERGE).
                        set(status.outcome == "merged" ? .landed : .reviewed, for: workspace)
                    } else {
                        // quorum pushes its fixes: the head it converged on merges.
                        proven[workspace.id] = nil
                        merge(workspace, checkout: checkout, pr: pr)
                    }
                } else if status.outcome == nil, status.isClean {
                    continue // its verdict isn't in quorum's history yet
                } else {
                    let open = status.open
                    set(.failed(open > 0 ? L("quorum stopped with %d open findings", open)
                                         : L("quorum stopped: %@", status.reason ?? status.outcome ?? "?")), for: workspace)
                }
            case .merging:
                if context.mergeability == .conflicting {
                    set(.failed(L("Conflicts appeared: land again")), for: workspace)
                }
            default:
                continue
            }
        }
        if !steps.values.contains(where: \.isActive) {
            timer?.invalidate()
            timer = nil
        }
    }

    /// quorum pushed its fixes: the session's checkout follows when it
    /// can without a merge (clean, nothing of its own on top).
    nonisolated static func takeFixes(in checkout: String) {
        Task.detached(priority: .utility) {
            let git = WorkState.git
            guard (Shell.run(git, ["status", "--porcelain"], in: checkout) ?? "x").isEmpty,
                  let branch = Shell.run(git, ["branch", "--show-current"], in: checkout), !branch.isEmpty,
                  Shell.execute(git, ["fetch", "--quiet", "origin", branch], in: checkout, timeout: 60).status == 0
            else { return }
            _ = Shell.execute(git, ["merge", "--ff-only", "--quiet", "FETCH_HEAD"], in: checkout, timeout: 120)
        }
    }

    // MARK: The agent

    private func agent(of workspace: Workspace) -> TerminalSession? {
        workspace.agentTab
    }

    /// Three asks per landing; then it stops and says so.
    private func mayAsk(_ workspace: Workspace) -> Bool {
        let count = (asks[workspace.id] ?? 0) + 1
        asks[workspace.id] = count
        if count > 3 {
            set(.failed(L("Still not ready after three rounds: your call")), for: workspace)
            return false
        }
        return true
    }

    private func ask(_ workspace: Workspace, _ step: String, _ message: String) {
        if workspace.sessions.contains(where: { $0.agent == .blocked }) {
            set(.failed(L("The agent asks you something: answer it, then land again")), for: workspace)
            return
        }
        guard let session = agent(of: workspace) else {
            set(.failed(step + " — " + L("no agent runs in this session")), for: workspace)
            return
        }
        guard mayAsk(workspace) else { return }
        RemoteState.type(message, enter: true, into: session)
        set(.waitingForAgent(step), for: workspace)
    }
}
