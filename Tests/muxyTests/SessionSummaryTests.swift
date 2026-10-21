import XCTest
@testable import muxy

final class SessionSummaryTests: XCTestCase {
    func testQuestionTakesPriorityOverOtherWork() {
        let status = SessionSummary.resolve(agent: .blocked, next: .accept, proving: true, quorumRunning: true)
        XCTAssertEqual(status?.text, L("Needs your answer"))
        XCTAssertEqual(status?.tone, .attention)
        XCTAssertFalse(status?.running ?? true)
    }

    func testRunningQuorumTakesPriorityOverAnOlderAcceptanceDecision() {
        let status = SessionSummary.resolve(agent: .idle, next: .accept, quorumRunning: true, quorumPhase: "fix")
        XCTAssertEqual(status?.text, L("Quorum is fixing the pull request"))
        XCTAssertTrue(status?.running ?? false)
    }

    func testWorkingDoesNotLookBlockedByCIThatTheAgentMayBeFixing() {
        XCTAssertEqual(SessionSummary.resolve(agent: .working, proving: true, prState: .open, checks: .failed)?.text,
                       L("Working · tests running"))
        XCTAssertEqual(SessionSummary.resolve(agent: .idle, next: .accept, prState: .open, checks: .failed)?.text,
                       L("CI failed"))
    }

    func testFailedLocalChecksTakePriorityOverACompletedDecision() {
        let proof = ProofResult(tree: "tree", entries: [
            .init(name: "test", command: "swift test", outcome: .failed, seconds: 1, tail: "failure", log: "")
        ], finished: Date())

        let status = SessionSummary.resolve(agent: .idle, next: .land, proof: proof)

        XCTAssertEqual(status?.text, L("Checks failed"))
        XCTAssertEqual(status?.tone, .failure)
    }

    func testLiveCollisionTakesPriorityOverACompletedDecision() {
        let status = SessionSummary.resolve(agent: .idle, next: .land, collision: L("conflicts with %@", "main"))

        XCTAssertEqual(status?.text, L("conflicts with %@", "main"))
        XCTAssertEqual(status?.tone, .attention)
    }

    func testOnlyOpenPullRequestsHaveMergeAndCIFailures() {
        XCTAssertEqual(SessionSummary.resolve(agent: .idle, prState: .merged, checks: .failed, mergeability: .conflicting)?.text, L("Merged"))
        XCTAssertEqual(SessionSummary.resolve(agent: .idle, prState: .closed, checks: .failed)?.text, L("Pull request closed"))
        XCTAssertEqual(SessionSummary.resolve(agent: .idle, next: .accept, prState: .open, mergeability: .conflicting)?.text,
                       L("Merge blocked by conflicts"))
    }

    func testQuietShellHasNoStatusAndAcceptanceIsExplicit() {
        XCTAssertNil(SessionSummary.resolve(agent: .none))
        XCTAssertEqual(SessionSummary.resolve(agent: .idle, next: .accept)?.text, L("Ready for your inspection"))
        XCTAssertEqual(SessionSummary.resolve(agent: .idle, next: .land)?.text, L("Ready to merge"))
    }

    func testShellCardKeepsActivityWhenItHasNoSummary() {
        let face = WingFace(title: "Shell", agent: .none, attention: false, isGit: false, pr: nil, prStatus: .none,
                            activity: "Building release", lines: [], agents: [], result: nil)

        XCTAssertNil(face.currentStatus)
        XCTAssertEqual(face.fallbackActivity, "Building release")
    }

    func testCompletedResultTakesPriorityOverAnIdleStatus() {
        let face = WingFace(title: "Task", agent: .idle, attention: false, isGit: true, pr: nil, prStatus: .none,
                            activity: "Done", lines: [], agents: [.idle], result: ResultFace(summary: "Finished"))

        XCTAssertTrue(face.showsResult)
        XCTAssertNil(face.currentStatus)
    }

    func testCardFormatsItsWebAppPort() {
        let face = WingFace(title: "Task", agent: .working, attention: false, isGit: true, pr: nil, prStatus: .none,
                            activity: "Working", lines: [], agents: [.working], result: nil, appPort: 3000)

        XCTAssertEqual(face.appPortText, L("app on :%@", "3000"))
    }

    func testCompletedQuorumOutcomeKeepsItsVerdict() {
        var quorum = QuorumStatus(kind: .babysit, key: "o/r#1", running: false, blockers: 2, outcome: "converged", date: Date())
        quorum.headSHA = "head"

        let status = SessionSummary.completedQuorum(quorum, head: "head")

        XCTAssertEqual(status?.text, L("quorum: clean, %d fixed", 2))
        XCTAssertEqual(status?.tone, .quiet)

        let failed = QuorumStatus(kind: .babysit, key: "o/r#1", running: false, outcome: "failed", date: Date())
        XCTAssertEqual(SessionSummary.completedQuorum(failed, head: "head")?.tone, .failure)

        let interrupted = QuorumStatus(kind: .babysit, key: "o/r#1", running: false, outcome: "interrupted", date: Date())
        XCTAssertEqual(SessionSummary.completedQuorum(interrupted, head: "head")?.tone, .attention)
    }
}

@MainActor
final class TerminalTabStatusTests: XCTestCase {
    func testShellAndIdleAgentDoNotClaimToBeWorking() {
        XCTAssertNil(TerminalSession.tabStatus(agent: .none, needsAttention: false, busy: false, planning: false))
        XCTAssertNil(TerminalSession.tabStatus(agent: .idle, needsAttention: false, busy: false, planning: false))
    }

    func testTabKeepsItsOwnErrorOrQuestionEvenWhileAnotherTabWorks() {
        let blocked = TerminalSession.tabStatus(agent: .blocked, needsAttention: true, busy: false, planning: false)
        let working = TerminalSession.tabStatus(agent: .working, needsAttention: false, busy: true, planning: false)
        let failed = TerminalSession.tabStatus(agent: .failed, needsAttention: true, busy: false, planning: false)
        XCTAssertEqual(blocked?.tone, .attention)
        XCTAssertEqual(working?.running, true)
        XCTAssertEqual(failed?.tone, .failure)
        XCTAssertNil(TerminalSession.tabStatus(agent: .none, needsAttention: false, busy: false, planning: false))
    }
}
