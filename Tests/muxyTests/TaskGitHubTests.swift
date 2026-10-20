import XCTest
@testable import muxy

final class TaskGitHubTests: XCTestCase {
    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    func testIssueStateRejectsMissingAndUnknownStates() throws {
        XCTAssertEqual(TaskGitHubSnapshot.issueState(from: try data(["state": "CLOSED"])), "CLOSED")
        XCTAssertEqual(TaskGitHubSnapshot.issueState(from: try data(["state": "OPEN"])), "OPEN")
        XCTAssertNil(TaskGitHubSnapshot.issueState(from: try data([:])))
        XCTAssertNil(TaskGitHubSnapshot.issueState(from: try data(["state": "NEW_FORMAT"])))
        XCTAssertNil(TaskGitHubSnapshot.issueState(from: Data("not json".utf8)))
    }

    func testPullRequestRequiresKnownStateAndCheckSchema() throws {
        XCTAssertNil(TaskGitHubSnapshot.pullRequest(from: try data(["number": 2, "state": "NEW", "statusCheckRollup": []])))
        XCTAssertNil(TaskGitHubSnapshot.pullRequest(from: try data(["number": 2, "state": "OPEN"])))
        XCTAssertNil(TaskGitHubSnapshot.pullRequest(from: try data(["number": 2, "state": "OPEN", "statusCheckRollup": [["newField": "green"]]])))
        XCTAssertNil(TaskGitHubSnapshot.pullRequest(from: try data(["number": 2, "state": "OPEN", "statusCheckRollup": [["status": "COMPLETED", "conclusion": "NEW"]]])))
        XCTAssertNil(TaskGitHubSnapshot.pullRequest(from: try data(["number": 2, "state": "OPEN", "statusCheckRollup": [["status": "COMPLETED", "conclusion": NSNull()]]])))
    }

    func testDistinguishesAbsentPendingFailedAndPassedCI() throws {
        let cases: [([[String: Any]], Checks)] = [
            ([], .none),
            ([["status": "IN_PROGRESS"]], .pending),
            ([["status": "COMPLETED", "conclusion": "FAILURE"]], .failed),
            ([["status": "COMPLETED", "conclusion": "SUCCESS"]], .passed),
            ([["state": "ERROR"]], .failed),
            ([["state": "PENDING"]], .pending)
        ]
        for (checks, expected) in cases {
            let pr = try XCTUnwrap(TaskGitHubSnapshot.pullRequest(from: data(["number": 2, "state": "MERGED", "statusCheckRollup": checks])))
            XCTAssertEqual(pr.checks, expected)
            XCTAssertEqual(pr.state, .merged)
        }
    }
}
