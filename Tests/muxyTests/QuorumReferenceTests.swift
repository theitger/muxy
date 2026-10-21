import XCTest
@testable import muxy

final class QuorumReferenceTests: XCTestCase {
    func testLegacyLogSessionKeepsThePRFromItsLogInsteadOfItsCheckout() throws {
        let reference = try XCTUnwrap(QuorumReference.fromLogTitle("tail -n +1 -F /Users/me/.muxy/quorum/babysit-4503-1721.log", root: "/main", repo: "o/r"))
        XCTAssertEqual(reference.root, "/main")
        XCTAssertEqual(reference.number, 4503)
        XCTAssertEqual(reference.repo, "o/r")
        XCTAssertNil(QuorumReference.fromLogTitle("echo tail /quorum/babysit-4503-1721.log", root: "/main", repo: "o/r"))
        XCTAssertNil(QuorumReference.fromLogTitle("tail /tmp/babysit-4503-1721.log", root: "/main", repo: "o/r"))
        XCTAssertNil(QuorumReference.fromLogTitle("tail /quorum/review-invalid-1.log", root: "/main", repo: "o/r"))
    }

    func testRunIdentitySurvivesRestoreAndOldSessionsStillDecode() throws {
        let reference = QuorumReference(root: "/main", number: 7, repo: "o/r", log: "/log")
        let saved = SavedSessions.Workspace(tabs: [], selected: nil, quorumReference: reference)
        let decoded = try JSONDecoder().decode(SavedSessions.Workspace.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.quorumReference, reference)
        let old = try JSONDecoder().decode(SavedSessions.Workspace.self, from: Data(#"{"tabs":[],"selected":null}"#.utf8))
        XCTAssertNil(old.quorumReference)
    }
}

@MainActor
final class QuorumSessionNavigationTests: XCTestCase {
    func testLogWorkspaceDoesNotNeedAContextPullRequestToResolveItsRun() {
        let workspace = Workspace(windowID: UUID())
        XCTAssertNil(workspace.context.pr)
        workspace.quorumReference = QuorumReference(root: "/main", number: 7, repo: "o/r")
        XCTAssertEqual(QuorumWatch.shared.reference(for: workspace), workspace.quorumReference)
    }

    func testOpeningQuorumPreservesTheSelectedWorkspaceAndTerminalTabs() {
        let window = WindowModel()
        let workspace = Workspace(windowID: window.id)
        window.select(workspace)
        window.showSection(.quorum)
        XCTAssertEqual(window.workSection, .quorum)
        XCTAssertEqual(window.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(window.destination, .workspace)
        XCTAssertTrue(workspace.sessions.isEmpty)
    }
}
