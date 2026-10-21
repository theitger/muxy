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

    enum Step: Equatable, Codable {
        case preparing(String)
        case waitingForLanding
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
            case .waitingForLanding: L("Waiting for the previous pull request to merge")
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
    enum Goal: String, Codable { case land, review }

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

    let journal = LandingJournal()
    private var restored = Set<String>()
    private var started: [Workspace.ID: Date] = [:]
    private var reviewAttempts: [Workspace.ID: Int] = [:]
    private var uncertain = Set<Workspace.ID>()
    private var autoMerges: [Workspace.ID: Bool] = [:]
    private var reconcilingQuorum = Set<Workspace.ID>()

    func resume() {
        guard !journal.persistenceBlocked else { return }
        if journal.receipts.values.contains(where: { $0.step.isActive }) { startTimer() }
    }

    private func recover() {
        guard HubModel.shared.updated != nil else { return }
        for receipt in journal.receipts.values where receipt.step.isActive && !restored.contains(receipt.id) {
            guard let workspace = Store.shared.workspaces.first(where: {
                $0.context.root == receipt.root && $0.context.branch == receipt.branch && $0.context.pr == receipt.pr
            }), !workspace.sessions.contains(where: { $0.preparing != nil }) else { continue }
            // Quorum's watcher must have had a chance to read its artifacts.
            restored.insert(receipt.id)
            runs[workspace.id, default: 0] += 1
            goals[workspace.id] = receipt.goal
            steps[workspace.id] = receipt.step
            stepSince[workspace.id] = receipt.since
            started[workspace.id] = receipt.started
            asks[workspace.id] = receipt.asks
            reviewAttempts[workspace.id] = receipt.reviewAttempts ?? 0
            autoMerges[workspace.id] = receipt.goal == .land && receipt.autoMerges == true
            if receipt.requiresInspection == true { uncertain.insert(workspace.id) }
            quorumSince[workspace.id] = receipt.quorumSince
            proven[workspace.id] = receipt.provenHead
            if workspace.context.prState == .merged { set(.landed, for: workspace); continue }
            switch receipt.recovery(agentWorking: workspace.agent == .working) {
            case .observe:
                break
            case .inspect:
                uncertain.insert(workspace.id)
                set(.failed(L("The previous operation needs inspection before continuing.")), for: workspace)
            case .check:
                if receipt.goal == .land, !hasMergeSlot(workspace) { set(.waitingForLanding, for: workspace) }
                else { advance(workspace) }
            }

        }
    }

    func requiresInspection(_ workspace: Workspace) -> Bool {
        if uncertain.contains(workspace.id) { return true }
        guard let root = workspace.context.root, let branch = workspace.context.branch else { return false }
        return journal.receipts[WorkItem.key(root: root, branch: branch)]?.requiresInspection == true
    }

    /// A deliberate retry acknowledges the uncertain earlier handoff.
    func allowRetry(root: String, branch: String) -> Bool {
        let key = WorkItem.key(root: root, branch: branch)
        guard var receipt = journal.receipts[key] else { return !journal.persistenceBlocked }
        guard !receipt.step.isActive else { return false }
        receipt.requiresInspection = false
        guard journal.put(receipt) else { return false }
        for workspace in Store.shared.workspaces where workspace.context.root == root && workspace.context.branch == branch {
            uncertain.remove(workspace.id)
        }
        return true
    }

    private func limits(for workspace: Workspace) -> AutomationLimits {
        Queue.shared.item(for: workspace)?.limits
            ?? TaskLedger.shared.record(for: TaskTarget(workspace: workspace)).limits
            ?? AutomationLimits()
    }

    func step(for workspace: Workspace) -> Step? { steps[workspace.id] }

    func canLand(_ workspace: Workspace) -> Bool {
        workspace.context.pr != nil && workspace.context.prState == .open && workspace.context.checkout != nil
            && workspace.context.root != nil && workspace.context.branch != nil
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
        if let problem = (journal.persistenceBlocked ? journal.problem : nil)
            ?? Queue.shared.problem
            ?? (TaskLedger.shared.persistenceBlocked ? TaskLedger.shared.problem : nil) {
            Store.shared.window(of: workspace)?.show(problem, seconds: 6)
            return
        }
        if let reason = Queue.shared.landingBlocker(for: workspace) {
            set(.failed(reason), for: workspace)
            return
        }
        goals[workspace.id] = goal
        started[workspace.id] = Date()
        reviewAttempts[workspace.id] = 0
        autoMerges[workspace.id] = goal == .land && QuorumBehavior.current.merges
        uncertain.remove(workspace.id)
        if let root = workspace.context.root, let branch = workspace.context.branch {
            restored.insert(WorkItem.key(root: root, branch: branch))
        }
        runs[workspace.id, default: 0] += 1
        asks[workspace.id] = 0
        if goal == .land, !hasMergeSlot(workspace) {
            set(.waitingForLanding, for: workspace)
        } else { advance(workspace) }
        startTimer()
    }

    private func hasMergeSlot(_ workspace: Workspace) -> Bool {
        guard let root = workspace.context.root else { return false }
        let candidate = MergeOrder.Entry(id: workspace.id.uuidString, root: root,
                                         started: started[workspace.id] ?? .distantFuture, waiting: true)
        let entries = Store.shared.workspaces.compactMap { other -> MergeOrder.Entry? in
            guard let root = other.context.root, let step = steps[other.id], step.isActive,
                  goals[other.id] == .land else { return nil }
            return MergeOrder.Entry(id: other.id.uuidString, root: root, started: started[other.id] ?? .distantFuture,
                                    waiting: step == .waitingForLanding)
        }
        return MergeOrder.mayStart(candidate, among: entries)
    }

    func cancel(_ workspace: Workspace) {
        runs[workspace.id, default: 0] += 1
        set(.failed(L("Automation paused.")), for: workspace)
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

    @discardableResult
    private func set(_ step: Step, for workspace: Workspace) -> Bool {
        if steps[workspace.id] != step { stepSince[workspace.id] = Date() }
        guard let root = workspace.context.root, let branch = workspace.context.branch, let pr = workspace.context.pr else {
            steps[workspace.id] = step
            return !step.isActive
        }
        let receipt = LandingReceipt(root: root, branch: branch, pr: pr, goal: goal(for: workspace), step: step,
                                     since: stepSince[workspace.id] ?? Date(), started: started[workspace.id] ?? Date(),
                                     asks: asks[workspace.id] ?? 0, quorumSince: quorumSince[workspace.id],
                                     provenHead: proven[workspace.id] ?? nil,
                                     reviewAttempts: reviewAttempts[workspace.id], requiresInspection: uncertain.contains(workspace.id), autoMerges: autoMerges[workspace.id])
        guard journal.put(receipt) else {
            steps[workspace.id] = .failed(journal.problem ?? L("Landing could not be saved."))
            return false
        }
        steps[workspace.id] = step
        return true
    }

    /// Still the landing that started this step, not cancelled meanwhile.
    private func current(_ workspace: Workspace, _ run: Int?) -> Bool {
        runs[workspace.id] == run && steps[workspace.id]?.isActive == true
            && !journal.persistenceBlocked && Queue.shared.problem == nil && !TaskLedger.shared.persistenceBlocked
    }

    /// quorum works on this run: the review goal, or landing with it.
    private func usesQuorum(_ workspace: Workspace) -> Bool {
        goal(for: workspace) == .review ? Quorum.isInstalled : withQuorum
    }

    /// A clean verdict for this PR is not enough: a later push invalidates it.
    nonisolated static func reviewCovers(_ status: QuorumStatus?, head: String?) -> Bool {
        status?.covers(head) == true
    }

    /// A finished babysit can push fixes, so its recorded final head must
    /// match GitHub before landing continues; the workspace context may lag.
    nonisolated static func quorumCovers(_ status: QuorumStatus, pull: Git.Lookup, pr: Int) -> Bool {
        guard let head = status.headSHA, status.covers(head), case let .found(pull) = pull,
              pull.number == pr, pull.head?.lowercased() == head.lowercased() else { return false }
        return status.outcome == "merged" ? pull.state == .merged : pull.state == .open
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
        guard set(.preparing(L("Looking at the branch")), for: workspace) else { return }
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
            let fetched = Shell.execute(git, ["fetch", "--quiet", "origin", String(start.dropFirst("origin/".count))], in: root, timeout: 60)
            guard fetched.status == 0 else {
                return Inspection(dirty: dirty, start: start, baseAvailable: false, behind: false, conflicts: [], unpushed: 1)
            }
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
        return Inspection(dirty: dirty, start: start, baseAvailable: true, behind: behind, conflicts: conflicts, unpushed: unpushed ?? 1,
                          fromOrigin: fromOrigin)
    }

    struct Inspection {
        var dirty: Bool
        var start: String
        /// False when the current base could not be fetched; stale refs must
        /// never be used to decide whether landing is safe.
        var baseAvailable: Bool
        var behind: Bool
        var conflicts: [String]
        /// Commits origin doesn't have (1 when there is no upstream yet).
        var unpushed: Int
        /// Commits origin's branch has that this checkout doesn't.
        var fromOrigin = 0
    }

    private func act(on state: Inspection, workspace: Workspace, checkout: String, root: String, pr: Int) {
        let run = runs[workspace.id]
        guard state.baseAvailable else {
            set(.failed(L("Couldn't fetch %@ from GitHub.", state.start)), for: workspace)
            return
        }
        if state.dirty {
            ask(workspace, L("The agent commits its remaining changes"),
                "Commit all remaining changes in this checkout with a clear message, then push the branch. Don't change anything else.")
            return
        }
        // quorum pushed fixes: taken in first, or the push below is refused.
        if state.fromOrigin > 0 {
            guard set(.preparing(L("Taking in quorum's fixes")), for: workspace) else { return }
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
            guard set(.preparing(L("Merging %@ in", state.start)), for: workspace) else { return }
            Task.detached(priority: .userInitiated) {
                let merged = Shell.execute(WorkState.git, ["merge", "--no-edit", "--quiet", state.start], in: checkout, timeout: 300)
                if merged.status != 0 {
                    _ = Shell.execute(WorkState.git, ["merge", "--abort"], in: checkout)
                }
                await MainActor.run {
                    guard self.current(workspace, run) else { return }
                    if merged.status == 0 {
                        if let repo = workspace.context.repo { Acceptance.shared.invalidate(repo: repo, pr: pr) }
                        workspace.primary?.refreshContext()
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
        guard set(.proving, for: workspace) else { return }
        Task.detached(priority: .userInitiated) {
            let checks = ProofCheck.load(root: root)
            let checkpoint = Self.checkedHead(in: checkout)
            await MainActor.run {
                guard self.current(workspace, run) else { return }
                guard let checkpoint else {
                    self.set(.failed(L("The checkout changed. Commit the changes and try again.")), for: workspace)
                    return
                }
                guard !checks.isEmpty else {
                    self.push(workspace, checkout: checkout, pr: pr, checkpoint: checkpoint)
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
                        guard self.set(.waitingForAgent(L("The agent fixes the failed checks")), for: workspace) else { return }
                        guard Proofs.sendFailures(result, to: session) else {
                            self.set(.failed(L("The failed checks could not be delivered. Check the terminal and retry.")), for: workspace)
                            return
                        }
                    case .cancelled:
                        self.set(.failed(L("Checks cancelled")), for: workspace)
                    case .passed, .skipped:
                        guard result.tree == checkpoint.tree else {
                            self.set(.failed(L("The checkout changed during checks. Run them again.")), for: workspace)
                            return
                        }
                        self.push(workspace, checkout: checkout, pr: pr, checkpoint: checkpoint)
                    }
                }
            }
        }
    }

    private func push(_ workspace: Workspace, checkout: String, pr: Int, checkpoint: CheckedHead) {
        let run = runs[workspace.id]
        guard let branch = workspace.context.branch else {
            set(.failed(L("The checkout changed. Commit the changes and try again.")), for: workspace)
            return
        }
        guard set(.pushing, for: workspace) else { return }
        let reviewStatus = QuorumWatch.shared.status(for: workspace)
        Task.detached(priority: .userInitiated) {
            guard Self.checkedHead(in: checkout) == checkpoint else {
                await MainActor.run {
                    guard self.current(workspace, run), self.steps[workspace.id] == .pushing else { return }
                    self.set(.failed(L("The checkout changed during checks. Run them again.")), for: workspace)
                    workspace.primary?.refreshContext()
                }
                return
            }
            let head = checkpoint.head
            // Publish the checked object, never the moving HEAD ref.
            let result = Shell.execute(WorkState.git, ["push", "--quiet", "origin", "\(head):refs/heads/\(branch)"], in: checkout, timeout: 1200)
            let unchanged = Self.checkedHead(in: checkout) == checkpoint
            await MainActor.run {
                guard self.current(workspace, run), self.steps[workspace.id] == .pushing else { return }
                guard result.status == 0 else {
                    let reason = result.error.split(separator: "\n").last.map(String.init) ?? ""
                    self.set(.failed(L("Push failed: %@", reason)), for: workspace)
                    return
                }
                guard unchanged else {
                    self.set(.failed(L("The checkout changed during checks. Run them again.")), for: workspace)
                    workspace.primary?.refreshContext()
                    return
                }
                self.proven[workspace.id] = head
                // The review goal always asks quorum; landing only when
                // quorum hasn't accepted exactly the commit just pushed.
                let review = self.goal(for: workspace) == .review
                if review || (self.withQuorum && !Self.reviewCovers(reviewStatus, head: head)) {
                    guard (self.reviewAttempts[workspace.id] ?? 0) < self.limits(for: workspace).reviewAttempts else {
                        self.set(.failed(L("Review attempt limit reached.")), for: workspace)
                        return
                    }
                    self.reviewAttempts[workspace.id, default: 0] += 1
                    self.quorumSince[workspace.id] = Date()
                    guard self.set(.reviewing, for: workspace) else { return }
                    QuorumWatch.shared.start(.babysit, in: workspace, allowAutoMerge: self.goal(for: workspace) == .land)
                } else {
                    self.merge(workspace, checkout: checkout, pr: pr)
                }
            }
        }
    }

    struct CheckedHead: Equatable {
        let head: String
        let tree: String
    }

    /// A proof belongs to a clean checkout and one immutable commit/tree pair.
    /// Failed status reads and edits made while reading are never treated as clean.
    nonisolated static func checkedHead(in checkout: String) -> CheckedHead? {
        guard let head = Shell.run(WorkState.git, ["rev-parse", "HEAD"], in: checkout),
              let tree = Shell.run(WorkState.git, ["rev-parse", "HEAD^{tree}"], in: checkout) else { return nil }
        let status = Shell.execute(WorkState.git, ["status", "--porcelain"], in: checkout)
        guard status.status == 0, status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Shell.run(WorkState.git, ["rev-parse", "HEAD"], in: checkout) == head else { return nil }
        return CheckedHead(head: head, tree: tree)
    }

    private func merge(_ workspace: Workspace, checkout: String, pr: Int) {
        guard goal(for: workspace) == .land else {
            set(.reviewed, for: workspace)
            return
        }
        let run = runs[workspace.id]
        // Pushed after the checks (quorum's fixes): only that head merges,
        // and only quorum's review vouches for it.
        let head = proven[workspace.id] ?? nil
        guard let head, !head.isEmpty else {
            set(.failed(L("The commit to merge could not be verified.")), for: workspace)
            return
        }
        guard Queue.shared.landingBlocker(for: workspace) == nil else {
            set(.failed(Queue.shared.landingBlocker(for: workspace) ?? L("Waiting for prerequisites to merge.")), for: workspace)
            return
        }
        if !hasMergeSlot(workspace) { set(.waitingForLanding, for: workspace); return }
        guard set(.merging(L("Handing it to GitHub")), for: workspace) else { return }
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
        if let problem = Queue.shared.problem
            ?? (TaskLedger.shared.persistenceBlocked ? TaskLedger.shared.problem : nil) {
            for workspace in Store.shared.workspaces where steps[workspace.id]?.isActive == true {
                runs[workspace.id, default: 0] += 1
                set(.failed(problem), for: workspace)
            }
            return
        }
        recover()
        for workspace in Store.shared.workspaces {
            guard let step = steps[workspace.id] else { continue }
            let context = workspace.context
            let limits = limits(for: workspace)
            if step.isActive, Date().timeIntervalSince(started[workspace.id] ?? Date()) > limits.seconds {
                runs[workspace.id, default: 0] += 1
                set(.failed(L("Task time limit reached. Automation paused.")), for: workspace)
                continue
            }
            if context.prState == .merged {
                if step != .landed {
                    set(.landed, for: workspace)
                    for other in Store.shared.workspaces where other.context.root == context.root { other.primary?.refreshContext() }
                    Radar.shared.poke(after: 0)
                }
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
            case .waitingForLanding:
                if hasMergeSlot(workspace), Queue.shared.landingBlocker(for: workspace) == nil {
                    // Fetch the current base and rerun checks after the preceding merge.
                    advance(workspace)
                }
            case .reviewing:
                guard let status = QuorumWatch.shared.status(for: workspace),
                      status.running || status.date > (quorumSince[workspace.id] ?? .distantFuture).addingTimeInterval(-5) else {
                    if Date().timeIntervalSince(quorumSince[workspace.id] ?? Date()) > Queue.settle {
                        uncertain.insert(workspace.id)
                        set(.failed(L("The quorum launch could not be confirmed. Inspect the run before retrying.")), for: workspace)
                    }
                    continue
                }
                guard !status.running else { continue }
                if status.succeeded, let checkout = context.checkout, let pr = context.pr {
                    reconcileQuorum(status, in: workspace, checkout: checkout, pr: pr)
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
        if !steps.values.contains(where: \.isActive),
           !journal.receipts.values.contains(where: { $0.step.isActive && !restored.contains($0.id) }) {
            timer?.invalidate()
            timer = nil
        }
    }

    private func reconcileQuorum(_ status: QuorumStatus, in workspace: Workspace, checkout: String, pr: Int) {
        guard let head = status.headSHA, status.covers(head) else {
            set(.failed(L("quorum's result does not cover the current commit. Review it again.")), for: workspace)
            return
        }
        guard reconcilingQuorum.insert(workspace.id).inserted else { return }
        let run = runs[workspace.id]
        Task.detached(priority: .userInitiated) {
            let pull = Git.pullRequest(in: checkout, number: pr)
            await MainActor.run {
                self.reconcilingQuorum.remove(workspace.id)
                guard self.current(workspace, run), self.steps[workspace.id] == .reviewing else { return }
                guard Self.quorumCovers(status, pull: pull, pr: pr) else {
                    self.set(.failed(L("quorum's result does not cover the current commit. Review it again.")), for: workspace)
                    workspace.primary?.refreshContext()
                    return
                }
                workspace.primary?.refreshContext()
                Self.takeFixes(in: checkout)
                if self.goal(for: workspace) == .review {
                    if status.outcome == "merged" {
                        self.set(.failed(L("quorum merged a review-only run.")), for: workspace)
                    } else {
                        self.set(.reviewed, for: workspace)
                    }
                } else if status.outcome == "merged" {
                    self.set(.landed, for: workspace)
                } else if self.autoMerges[workspace.id] == true {
                    self.proven[workspace.id] = head
                    self.set(.merging(L("Waiting for quorum's merge on GitHub")), for: workspace)
                } else {
                    // quorum may have pushed fixes. Merge only the final
                    // head recorded by that run; GitHub rejects a later push.
                    self.proven[workspace.id] = head
                    self.merge(workspace, checkout: checkout, pr: pr)
                }
            }
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
        let limit = (limits(for: workspace)).repairAttempts
        if count > limit {
            set(.failed(L("Repair attempt limit reached. Inspect the task before retrying.")), for: workspace)
            return false
        }
        asks[workspace.id] = count
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
        guard set(.waitingForAgent(step), for: workspace) else { return }
        guard RemoteState.type(message, enter: true, into: session) else {
            set(.failed(L("The request could not be delivered. Check the terminal and retry.")), for: workspace)
            return
        }
    }
}
