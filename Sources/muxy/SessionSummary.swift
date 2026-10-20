import SwiftUI

/// One current activity or decision. Historical evidence stays in task details.
struct SessionSummary: Equatable {
    enum Tone { case quiet, active, attention, failure }
    var text: String
    var tone: Tone = .quiet
    var running = false

    static func completedQuorum(_ quorum: QuorumStatus, head: String?) -> Self? {
        guard !quorum.running, quorum.outcome != nil,
              !quorum.succeeded || quorum.covers(head) else { return nil }
        let tone: Tone = quorum.succeeded ? .quiet : (quorum.interrupted ? .attention : .failure)
        return Self(text: quorum.summary(for: head), tone: tone)
    }

    static func resolve(agent: AgentState, next: NextStep = .none, proving: Bool = false, proof: ProofResult? = nil,
                        quorumRunning: Bool = false, quorumPhase: String? = nil,
                        prState: Git.PullRequest.State? = nil, checks: Checks = .none,
                        mergeability: Mergeability = .unknown, collision: String? = nil) -> Self? {
        if next == .approvePlan { return Self(text: L("Plan ready for approval"), tone: .attention) }
        if agent == .blocked { return Self(text: L("Needs your answer"), tone: .attention) }
        if quorumRunning {
            let text: String
            switch quorumPhase {
            case "fix": text = L("Quorum is fixing the pull request")
            case "ci": text = L("Quorum is checking CI")
            default: text = L("Quorum is reviewing the pull request")
            }
            return Self(text: text, tone: .active, running: true)
        }
        switch next {
        case let .landing(text), let .reviewing(text): return Self(text: text, tone: .active, running: true)
        default: break
        }
        if agent == .failed { return Self(text: L("Agent stopped with an error"), tone: .failure) }
        if agent == .working {
            return Self(text: proving ? L("Working · tests running") : L("Working"), tone: .active, running: true)
        }
        if proving { return Self(text: L("Tests running"), tone: .active, running: true) }
        if proof?.verdict == .failed { return Self(text: L("Checks failed"), tone: .failure) }
        if let collision { return Self(text: collision, tone: .attention) }
        if prState == .merged { return Self(text: L("Merged")) }
        if prState == .closed { return Self(text: L("Pull request closed")) }
        if prState == .open, mergeability == .conflicting {
            return Self(text: L("Merge blocked by conflicts"), tone: .attention)
        }
        if prState == .open, checks == .failed { return Self(text: L("CI failed"), tone: .failure) }
        switch next {
        case .answer: return Self(text: L("Needs your answer"), tone: .attention)
        case .accept: return Self(text: L("Ready for your inspection"), tone: .attention)
        case .openPR: return Self(text: L("Ready to open a pull request"))
        case .review: return Self(text: L("Ready for Quorum"))
        case .fix: return Self(text: L("Pull request needs attention"), tone: .attention)
        case .land: return Self(text: L("Ready to merge"))
        case let .wait(text): return Self(text: text)
        default: return agent == .idle ? Self(text: L("Waiting for your next prompt")) : nil
        }
    }
}

struct SessionSummaryLine: View {
    let status: SessionSummary

    private var color: Color {
        switch status.tone {
        case .quiet, .active: Theme.textMuted
        case .attention: Theme.orange.strong
        case .failure: Theme.red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if status.running {
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 10, height: 10)
            } else if status.tone == .attention || status.tone == .failure {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(status.text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11.5)).foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

extension Workspace {
    var sessionStatus: SessionSummary? {
        let quorum = QuorumWatch.shared.status(for: self)
        let collisions = Radar.shared.collisions(for: context.checkout)
        let collision = collisions.first(where: \.withBase) ?? collisions.first
        return SessionSummary.resolve(agent: agent, next: Flow.next(for: self),
                                     proving: Proofs.shared.isRunning(context.checkout),
                                     proof: Proofs.shared.result(for: context.checkout),
                                     quorumRunning: quorum?.running == true, quorumPhase: quorum?.phase,
                                     prState: context.pr == nil ? nil : context.prState,
                                     checks: context.checks, mergeability: context.mergeability,
                                     collision: collision.map(Radar.shared.describe))
    }
}
