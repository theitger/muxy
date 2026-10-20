import Foundation

/// The one thing a session needs next, from working to merged. muxy
/// suggests it; you take it with one click. Nothing here runs by itself:
/// a PR, a review, a landing all start when you say so (except a review
/// when you turned on starting quorum as soon as a PR opens).
enum NextStep: Equatable {
    /// Nothing to do but wait; the words say for what.
    case wait(String)
    /// The agent asks you something.
    case answer
    /// The agent's plan waits for your go-ahead.
    case approvePlan
    /// Work is there, no pull request yet.
    case openPR
    /// A pull request nobody reviewed yet: quorum's babysit reviews it,
    /// fixes what it finds and waits for CI, as you run it yourself.
    case review
    /// The review found something, CI is red, or the base conflicts.
    case fix(String)
    /// Reviewed, green, mergeable.
    case land
    /// quorum (or muxy getting the branch ready for it) works on the PR.
    case reviewing(String)
    /// Landing runs.
    case landing(String)
    /// Merged, closed, or nothing started.
    case none

    var title: String {
        switch self {
        case let .wait(text): text
        case .answer: L("Answer the agent")
        case .approvePlan: L("Approve the plan")
        case .openPR: L("Open a pull request")
        case .review: L("Review and fix with quorum")
        case let .fix(why): why
        case .land: L("Land")
        case let .reviewing(text): text
        case let .landing(text): text
        case .none: ""
        }
    }

    /// The board's column for it.
    var stage: Stage {
        switch self {
        case .wait, .answer, .approvePlan, .openPR: .working
        case .review, .fix, .reviewing: .review
        case .land, .landing: .ready
        case .none: .none
        }
    }

    enum Stage { case working, review, ready, none }
}

@MainActor
enum Flow {
    /// Start quorum (review and fix) as soon as a session's pull request opens.
    static let autoReviewKey = "reviewWhenPROpens"

    static func next(for workspace: Workspace) -> NextStep {
        let context = workspace.context
        guard context.repo != nil else { return .none }
        if let step = Landing.shared.step(for: workspace), step.isActive || step == .landed {
            if step == .landed { return .none }
            return Landing.shared.goal(for: workspace) == .review ? .reviewing(step.text) : .landing(step.text)
        }
        if let planner = workspace.sessions.first(where: \.planning), Self.planReady(planner) { return .approvePlan }
        if workspace.agent == .blocked { return .answer }
        if workspace.agent == .working { return .wait(L("Working")) }
        guard let pr = context.pr else {
            let changed = Results.shared.result(for: workspace)?.changes?.files ?? 0
            if changed > 0, workspace.agentTab != nil { return .openPR }
            return workspace.agentTab != nil ? .wait(L("Waiting for your next prompt")) : .none
        }
        _ = pr
        guard context.prState == .open else { return .none }
        let quorumInstalled = Quorum.isInstalled
        let review = QuorumWatch.shared.status(for: workspace)
        if let step = quorumStep(review, installed: quorumInstalled) { return step }
        if context.mergeability == .conflicting { return .fix(L("Resolve conflicts")) }
        switch context.checks {
        case .failed: return .fix(L("Fix CI"))
        case .pending: return .wait(L("CI is running"))
        case .passed, .none: break
        }
        if Proofs.shared.result(for: context.checkout)?.verdict == .failed { return .fix(L("Fix the checks")) }
        return .land
    }

    /// What quorum's state asks for, if anything. quorum's babysit always
    /// reviews first, then fixes: there is no "fix these findings" without
    /// it. A review that only commented (or none yet) leads to it; a
    /// babysit that stopped is run again, its reason on the card.
    nonisolated static func quorumStep(_ status: QuorumStatus?, installed: Bool) -> NextStep? {
        if let status, status.running { return .reviewing(status.summary) }
        guard installed else { return nil }
        guard let status else { return .review }
        if status.succeeded { return nil }
        return status.kind == .review ? .review : .fix(L("Run quorum again"))
    }

    /// Asked of Codex, which has no plan mode of its own.
    nonisolated static let planNote = """
    First make a plan: read what you need, then write the plan (what you'll change, where, how you'll test it) and stop. Change no files until I say go.
    """

    /// The plan is there: Claude asks to leave its plan mode, Codex
    /// ended the turn it was asked to plan in.
    static func planReady(_ session: TerminalSession) -> Bool {
        switch session.kind {
        case .claude: session.agent == .blocked
        case .codex: session.agent == .idle && session.turnsEnded > 0
        case nil: false
        }
    }

    /// The go-ahead: Claude's own "yes" (the first, which goes on without
    /// asking when permissions are skipped), Codex told to go.
    static func approvePlan(in session: TerminalSession) -> Bool {
        // Started without skipped permissions so the plan would wait: the
        // same conversation goes on with them, told to go.
        if session.kind == .claude, session.skipsPermissions, let id = session.agentSessionID,
           let workspace = Store.shared.workspaces.first(where: { $0.sessions.contains { $0 === session } }) {
            let go = TerminalSession(
                directory: session.cwd,
                command: Launcher.shellCommand(running: AgentKind.claude.command(
                    .resume(id: id), skipPermissions: true, resumePrompt: true
                )),
                environment: ["MUXY_PROMPT": "The plan is approved: implement it."]
            )
            go.kind = .claude
            go.agentSessionID = id
            go.skipsPermissions = true
            go.issue = session.issue
            go.variantGroup = session.variantGroup
            go.agent = .working
            Store.shared.replace(session, with: go, in: workspace)
            return true
        }
        switch session.kind {
        case .claude:
            let choices = Inbox.choices(of: session)
            guard let yes = choices.first(where: { $0.label.lowercased().hasPrefix("yes") }) ?? choices.first else { return false }
            Inbox.choose(yes, in: session)
        case .codex:
            RemoteState.type("Go ahead: implement the plan.", enter: true, into: session)
        case nil:
            return false
        }
        session.planning = false
        return true
    }

    /// Takes the step. Returns false when it can't (no agent to ask).
    @discardableResult
    static func take(_ step: NextStep, in workspace: Workspace, window: WindowModel) -> Bool {
        switch step {
        case .approvePlan:
            guard let planner = workspace.sessions.first(where: \.planning) else { return false }
            return approvePlan(in: planner)
        case .answer:
            window.showHub = false
            Store.shared.select(workspace, session: workspace.sessions.first { $0.agent == .blocked })
        case .openPR:
            guard let agent = workspace.agentTab else { return false }
            let closes = workspace.sessions.lazy.compactMap(\.issue).first.map { " that closes #\($0.number)" } ?? ""
            RemoteState.type(
                "Commit your work, push the branch and open a pull request\(closes). Fill in the repository's pull request template if it has one.",
                enter: true, into: agent
            )
        case .review:
            Landing.shared.review(workspace)
        case .fix:
            // quorum's babysit fixes findings and CI (and conflicts, with
            // RESOLVE_CONFLICTS), after the branch is made ready for it;
            // without quorum the agent gets the job.
            if Quorum.isInstalled, workspace.context.pr != nil {
                Landing.shared.review(workspace)
            } else if let agent = workspace.agentTab {
                RemoteState.type("The pull request isn't ready: CI or checks fail, or it conflicts with its base. Find out why, fix it, and push.", enter: true, into: agent)
            } else {
                return false
            }
        case .land:
            Landing.shared.land(workspace)
        case .wait, .reviewing, .landing, .none:
            return false
        }
        return true
    }

    /// A pull request appeared for a session: reviewed right away, when
    /// you asked for that.
    static func pullRequestOpened(in workspace: Workspace) {
        guard UserDefaults.standard.bool(forKey: autoReviewKey), Quorum.isInstalled,
              QuorumWatch.shared.status(for: workspace) == nil else { return }
        Landing.shared.review(workspace)
    }
}
