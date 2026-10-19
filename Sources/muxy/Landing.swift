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
        /// Handed to GitHub: merges when checks and rules allow.
        case merging(String)
        case landed
        case failed(String)

        var isActive: Bool {
            switch self {
            case .landed, .failed: false
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

    @Published private(set) var steps: [Workspace.ID: Step] = [:]
    /// When quorum was asked, so an older run's verdict doesn't count.
    private var quorumSince: [Workspace.ID: Date] = [:]
    private var timer: Timer?
    /// The agent asked for something this many times in one landing: then
    /// it is your call, not another loop.
    private var asks: [Workspace.ID: Int] = [:]

    func step(for workspace: Workspace) -> Step? { steps[workspace.id] }

    func canLand(_ workspace: Workspace) -> Bool {
        workspace.context.pr != nil && workspace.context.prState == .open && workspace.context.checkout != nil
    }

    func land(_ workspace: Workspace) {
        guard canLand(workspace) else { return }
        asks[workspace.id] = 0
        advance(workspace)
        startTimer()
    }

    func cancel(_ workspace: Workspace) {
        steps[workspace.id] = nil
        quorumSince[workspace.id] = nil
    }

    /// The agent's turn ended: a landing waiting on it goes on.
    func turnEnded(in workspace: Workspace) {
        guard case .waitingForAgent = steps[workspace.id] else { return }
        // Give the push that often ends a turn a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.advance(workspace) }
    }

    // MARK: Steps

    private func advance(_ workspace: Workspace) {
        guard let checkout = workspace.context.checkout, let root = workspace.context.root,
              let pr = workspace.context.pr else { return }
        if workspace.sessions.contains(where: { $0.agent == .working }) {
            steps[workspace.id] = .waitingForAgent(L("Waiting for the agent's turn to end"))
            return
        }
        steps[workspace.id] = .preparing(L("Looking at the branch"))
        Task.detached(priority: .userInitiated) {
            let state = Self.inspect(checkout: checkout, root: root)
            await MainActor.run { self.act(on: state, workspace: workspace, checkout: checkout, root: root, pr: pr) }
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
        return Inspection(dirty: dirty, start: start, behind: behind, conflicts: conflicts, unpushed: unpushed ?? 1)
    }

    struct Inspection {
        var dirty: Bool
        var start: String
        var behind: Bool
        var conflicts: [String]
        /// Commits origin doesn't have (1 when there is no upstream yet).
        var unpushed: Int
    }

    private func act(on state: Inspection, workspace: Workspace, checkout: String, root: String, pr: Int) {
        guard steps[workspace.id] != nil else { return } // cancelled meanwhile
        if state.dirty {
            ask(workspace, L("The agent commits its remaining changes"),
                "Commit all remaining changes in this checkout with a clear message, then push the branch. Don't change anything else.")
            return
        }
        if state.behind, !state.conflicts.isEmpty {
            let files = state.conflicts.prefix(20).map { "- \($0)" }.joined(separator: "\n")
            ask(workspace, L("The agent resolves conflicts with %@", state.start),
                "Merge \(state.start) into this branch (git fetch first). These files conflict:\n\(files)\n\nResolve each conflict keeping both sides' intent, run the relevant tests, commit the merge and push.")
            return
        }
        if state.behind {
            steps[workspace.id] = .preparing(L("Merging %@ in", state.start))
            Task.detached(priority: .userInitiated) {
                let merged = Shell.execute(WorkState.git, ["merge", "--no-edit", "--quiet", state.start], in: checkout, timeout: 300)
                await MainActor.run {
                    if merged.status == 0 {
                        self.prove(workspace, checkout: checkout, root: root, pr: pr)
                    } else {
                        _ = Shell.execute(WorkState.git, ["merge", "--abort"], in: checkout)
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
        let checks = ProofCheck.load(root: root)
        guard !checks.isEmpty else {
            push(workspace, checkout: checkout, pr: pr)
            return
        }
        steps[workspace.id] = .proving
        Proofs.shared.run(checkout: checkout, root: root, checks: checks) { [weak self] result in
            guard let self, self.steps[workspace.id] == .proving else { return }
            guard let result else {
                self.steps[workspace.id] = .failed(L("The checks couldn't run"))
                return
            }
            if result.verdict == .failed, let session = self.agent(of: workspace) {
                guard self.mayAsk(workspace) else { return }
                Proofs.sendFailures(result, to: session)
                self.steps[workspace.id] = .waitingForAgent(L("The agent fixes the failed checks"))
                return
            }
            if result.verdict == .cancelled {
                self.steps[workspace.id] = .failed(L("Checks cancelled"))
                return
            }
            self.push(workspace, checkout: checkout, pr: pr)
        }
    }

    private func push(_ workspace: Workspace, checkout: String, pr: Int) {
        steps[workspace.id] = .pushing
        Task.detached(priority: .userInitiated) {
            let result = Shell.execute(WorkState.git, ["push", "--quiet", "origin", "HEAD"], in: checkout, timeout: 1200)
            await MainActor.run {
                guard self.steps[workspace.id] == .pushing else { return }
                guard result.status == 0 else {
                    let reason = result.error.split(separator: "\n").last.map(String.init) ?? ""
                    self.steps[workspace.id] = .failed(L("Push failed: %@", reason))
                    return
                }
                if self.withQuorum {
                    self.quorumSince[workspace.id] = Date()
                    self.steps[workspace.id] = .reviewing
                    QuorumWatch.shared.start(.babysit, in: workspace)
                } else {
                    self.merge(workspace, checkout: checkout, pr: pr)
                }
            }
        }
    }

    private func merge(_ workspace: Workspace, checkout: String, pr: Int) {
        steps[workspace.id] = .merging(L("Handing it to GitHub"))
        Task.detached(priority: .userInitiated) {
            let outcome = Self.enableMerge(pr: pr, in: checkout)
            await MainActor.run {
                guard case .merging = self.steps[workspace.id] else { return }
                switch outcome {
                case let .armed(text): self.steps[workspace.id] = .merging(text)
                case .merged: self.steps[workspace.id] = .landed
                case let .failed(text): self.steps[workspace.id] = .failed(text)
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

    /// `gh pr merge --auto` with the repository's own default method; where
    /// auto-merge is off, a direct merge (GitHub refuses it until allowed).
    nonisolated static func enableMerge(pr: Int, in checkout: String) -> MergeOutcome {
        guard let gh = Shell.find("gh") else { return .failed(L("gh is not installed.")) }
        let view = Shell.execute(gh, ["repo", "view", "--json", "viewerDefaultMergeMethod"], in: checkout, timeout: 30)
        let method = (try? JSONSerialization.jsonObject(with: Data(view.output.utf8)) as? [String: Any])?["viewerDefaultMergeMethod"] as? String
        let flag = switch method {
        case "SQUASH": "--squash"
        case "REBASE": "--rebase"
        default: "--merge"
        }
        let auto = Shell.execute(gh, ["pr", "merge", String(pr), "--auto", flag], in: checkout, timeout: 60)
        if auto.status == 0 { return .armed(L("Merges when GitHub allows it")) }
        let direct = Shell.execute(gh, ["pr", "merge", String(pr), flag], in: checkout, timeout: 60)
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
                steps[workspace.id] = .landed
                continue
            }
            switch step {
            case .reviewing:
                guard let status = QuorumWatch.shared.status(for: workspace), !status.running,
                      status.date > (quorumSince[workspace.id] ?? .distantFuture).addingTimeInterval(-5)
                else { continue }
                if status.isClean, let checkout = context.checkout, let pr = context.pr {
                    merge(workspace, checkout: checkout, pr: pr)
                } else {
                    steps[workspace.id] = .failed(L("quorum stopped with %d open findings", status.blockers + status.critical))
                }
            case .merging:
                if context.mergeability == .conflicting {
                    steps[workspace.id] = .failed(L("Conflicts appeared: land again"))
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

    // MARK: The agent

    private func agent(of workspace: Workspace) -> TerminalSession? {
        workspace.sessions.first { $0.kind != nil && $0.agent != .none }
    }

    /// Three asks per landing; then it stops and says so.
    private func mayAsk(_ workspace: Workspace) -> Bool {
        let count = (asks[workspace.id] ?? 0) + 1
        asks[workspace.id] = count
        if count > 3 {
            steps[workspace.id] = .failed(L("Still not ready after three rounds: your call"))
            return false
        }
        return true
    }

    private func ask(_ workspace: Workspace, _ step: String, _ message: String) {
        guard let session = agent(of: workspace) else {
            steps[workspace.id] = .failed(step + " — " + L("no agent runs in this session"))
            return
        }
        guard mayAsk(workspace) else { return }
        RemoteState.type(message, enter: true, into: session)
        steps[workspace.id] = .waitingForAgent(step)
    }
}
