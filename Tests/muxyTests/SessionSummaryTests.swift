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
}
