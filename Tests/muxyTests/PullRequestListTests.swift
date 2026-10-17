import XCTest
@testable import muxy

/// One `gh pr list` answering many sessions of a repository at once.
final class PullRequestListTests: XCTestCase {
    private func row(_ number: Int, _ branch: String, _ state: String = "OPEN") -> [String: Any] {
        ["number": number, "headRefName": branch, "state": state, "mergeStateStatus": "CLEAN"]
    }

    private func number(_ lookup: Git.Lookup?) -> Int? {
        if case let .found(pr) = lookup { return pr.number }
        return nil
    }

    func testNewestPullRequestOfABranchWins() {
        let rows = [row(9, "feat/a"), row(4, "feat/a", "CLOSED"), row(7, "feat/b", "MERGED")]
        let answers = Git.answers(from: rows, branches: ["feat/a", "feat/b"], limit: 40)
        XCTAssertEqual(number(answers["feat/a"]), 9)
        XCTAssertEqual(number(answers["feat/b"]), 7)
        if case let .found(pr) = answers["feat/b"] { XCTAssertEqual(pr.state, .merged) } else { XCTFail() }
    }

    func testMissingBranchHasNoPullRequestWhenTheListIsComplete() {
        let answers = Git.answers(from: [row(1, "other")], branches: ["feat/a"], limit: 40)
        guard case .none? = answers["feat/a"] else { return XCTFail("expected no PR") }
    }

    func testMissingBranchStaysUnansweredWhenTheListIsFull() {
        let rows = (1 ... 3).map { row($0, "other-\($0)") }
        let answers = Git.answers(from: rows, branches: ["feat/a"], limit: 3)
        XCTAssertNil(answers["feat/a"], "an older PR may exist beyond the page: ask gh pr view")
    }

    func testBranchesNobodyAskedForAreIgnored() {
        let answers = Git.answers(from: [row(5, "feat/x")], branches: ["feat/a"], limit: 40)
        XCTAssertNil(answers["feat/x"])
    }
}
