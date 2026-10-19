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
    /// Work is there, no pull request yet.
    case openPR
    /// A pull request nobody reviewed yet: quorum's babysit reviews it,
    /// fixes what it finds and waits for CI, as you run it yourself.
    case review
    /// The review found something, CI is red, or the base conflicts.
    case fix(String)
    /// Reviewed, green, mergeable.
    case land
    /// Landing runs.
    case landing(String)
    /// Merged, closed, or nothing started.
    case none

    var title: String {
        switch self {
        case let .wait(text): text
        case .answer: L("Answer the agent")
        case .openPR: L("Open a pull request")
        case .review: L("Review and fix with quorum")
        case let .fix(why): why
        case .land: L("Land")
        case let .landing(text): text
        case .none: ""
        }
    }

    /// The board's column for it.
    var stage: Stage {
        switch self {
        case .wait, .answer, .openPR: .working
        case .review, .fix: .review
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
            return step == .landed ? .none : .landing(step.text)
        }
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
        if let review, review.running { return .wait(review.summary) }
        if quorumInstalled, review == nil { return .review }
        if let review, !review.succeeded {
            let open = review.open
            return .fix(open > 0 ? L("Fix %d findings", open) : L("Review again"))
        }
        if context.mergeability == .conflicting { return .fix(L("Resolve conflicts")) }
        switch context.checks {
        case .failed: return .fix(L("Fix CI"))
        case .pending: return .wait(L("CI is running"))
        case .passed, .none: break
        }
        if Proofs.shared.result(for: context.checkout)?.verdict == .failed { return .fix(L("Fix the checks")) }
        return .land
    }

    /// Takes the step. Returns false when it can't (no agent to ask).
    @discardableResult
    static func take(_ step: NextStep, in workspace: Workspace, window: WindowModel) -> Bool {
        switch step {
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
            QuorumWatch.shared.start(.babysit, in: workspace)
        case .fix:
            // quorum's babysit fixes findings, CI and (when set) conflicts;
            // without quorum the agent gets the job.
            if Quorum.isInstalled, workspace.context.pr != nil {
                QuorumWatch.shared.start(.babysit, in: workspace)
            } else if let agent = workspace.agentTab {
                RemoteState.type("The pull request isn't ready: CI or checks fail, or it conflicts with its base. Find out why, fix it, and push.", enter: true, into: agent)
            } else {
                return false
            }
        case .land:
            Landing.shared.land(workspace)
        case .wait, .landing, .none:
            return false
        }
        return true
    }

    /// A pull request appeared for a session: reviewed right away, when
    /// you asked for that.
    static func pullRequestOpened(in workspace: Workspace) {
        guard UserDefaults.standard.bool(forKey: autoReviewKey), Quorum.isInstalled,
              QuorumWatch.shared.status(for: workspace) == nil else { return }
        QuorumWatch.shared.start(.babysit, in: workspace)
    }
}
