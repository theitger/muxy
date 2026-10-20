import XCTest
@testable import muxy

final class AcceptanceFeedbackTests: XCTestCase {
    func testEmptyFeedbackDoesNotStartAnAgent() {
        XCTAssertNil(AcceptanceFeedback.compose(
            feedback: " \n ", screenshot: nil, comments: [], checkout: "/tmp/work", repo: "owner/repo", pr: 42, newChat: true
        ))
    }

    func testNewChatGetsTheCheckoutAndScreenshotContext() throws {
        let screenshot = URL(fileURLWithPath: "/tmp/phone-preview.png")
        let prompt = try XCTUnwrap(AcceptanceFeedback.compose(
            feedback: "Fix the spacing", screenshot: screenshot, comments: [], checkout: "/tmp/work",
            repo: "owner/repo", pr: 42, newChat: true
        ))
        XCTAssertTrue(prompt.contains("/tmp/work"))
        XCTAssertTrue(prompt.contains("owner/repo PR #42"))
        XCTAssertTrue(prompt.contains("Fix the spacing"))
        XCTAssertTrue(prompt.contains(screenshot.path))
        XCTAssertTrue(prompt.contains("Commit and push"))
    }
}
