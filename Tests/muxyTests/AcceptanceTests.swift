import XCTest
@testable import muxy

final class AcceptanceTests: XCTestCase {
    func testOnlyTheCleanPullRequestHeadCanBeAccepted() throws {
        let repo = try TempRepo()
        let head = try repo.head()
        XCTAssertEqual(Acceptance.readiness(checkout: repo.root, expected: nil), .noHead)
        XCTAssertEqual(Acceptance.readiness(checkout: repo.root, expected: head), .ready(head))

        try repo.write("new.txt", "visible only in the worktree\n")
        XCTAssertEqual(Acceptance.readiness(checkout: repo.root, expected: head), .uncommitted)
        try repo.commit("New implementation")
        let changed = try repo.head()
        XCTAssertEqual(Acceptance.readiness(checkout: repo.root, expected: head), .changed)
        XCTAssertEqual(Acceptance.readiness(checkout: repo.root, expected: changed), .ready(changed))
    }

    func testQuorumLaunchRequiresTheFreshAcceptedPullRequestHead() {
        let accepted = String(repeating: "a", count: 40)
        let changed = String(repeating: "b", count: 40)
        func pull(_ head: String?, state: Git.PullRequest.State = .open) -> Git.Lookup {
            .found(Git.PullRequest(number: 7, state: state, head: head, checks: .none, isDraft: false, mergeability: .clean))
        }

        XCTAssertNotNil(Acceptance.acceptedOpenPullRequest(pull(accepted), number: 7, acceptedHead: accepted))
        XCTAssertNil(Acceptance.acceptedOpenPullRequest(pull(changed), number: 7, acceptedHead: accepted))
        XCTAssertNil(Acceptance.acceptedOpenPullRequest(pull(accepted, state: .closed), number: 7, acceptedHead: accepted))
    }

    func testQuorumCompletionUsesItsFinalHeadInsteadOfStaleContext() {
        let old = String(repeating: "a", count: 40)
        let final = String(repeating: "b", count: 40)
        var status = QuorumStatus(kind: .babysit, key: "o/r#7", running: false, outcome: "converged", date: Date())
        status.headSHA = final
        let matching = Git.Lookup.found(Git.PullRequest(number: 7, state: .open, head: final, checks: .passed, isDraft: false, mergeability: .clean))
        let stale = Git.Lookup.found(Git.PullRequest(number: 7, state: .open, head: old, checks: .passed, isDraft: false, mergeability: .clean))

        XCTAssertTrue(Landing.quorumCovers(status, pull: matching, pr: 7))
        XCTAssertFalse(Landing.quorumCovers(status, pull: stale, pr: 7))
    }

    func testLandingRequiresAcceptanceAfterMergingAnUpdatedBase() throws {
        let repo = try TempRepo()
        let checkout = try repo.addWorktree("feature", branch: "feature")
        try repo.write("feature.txt", "feature\n", in: checkout)
        try repo.commit("Feature", in: checkout)
        let accepted = try repo.head(in: checkout)
        XCTAssertEqual(Landing.checkedOutAcceptedHead(in: checkout, accepted: accepted), accepted)

        try repo.write("base.txt", "base\n")
        try repo.commit("Base update")
        try repo.git("merge", "--no-edit", "main", in: checkout)
        XCTAssertNil(Landing.checkedOutAcceptedHead(in: checkout, accepted: accepted))
    }
}
