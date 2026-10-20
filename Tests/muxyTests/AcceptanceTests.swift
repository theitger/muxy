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
}
