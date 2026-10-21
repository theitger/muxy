import XCTest
@testable import muxy

final class TaskCardExcerptTests: XCTestCase {
    func testDescriptionBecomesReadableTextWithoutTemplateComments() {
        let body = """
        <!-- Fill out this template. -->
        ## Expected behaviour
        Keep **all labels** and [details](https://example.com/details).
        - [x] Works on `MacBook`
        ![screenshot](https://example.com/image.png)
        """
        XCTAssertEqual(TaskCardExcerpt.text(body), "Expected behaviour Keep all labels and details. Works on MacBook")
    }

    func testMissingEmptyOrCommentOnlyDescriptionsHaveNoPlaceholder() {
        XCTAssertEqual(TaskCardExcerpt.text(nil), "")
        XCTAssertEqual(TaskCardExcerpt.text(" \n\t "), "")
        XCTAssertEqual(TaskCardExcerpt.text("<!-- internal template -->"), "")
        XCTAssertEqual(TaskCardExcerpt.text("<!-- unfinished template"), "")
    }

    func testLargeDescriptionsAndCodeFencesStayBounded() {
        XCTAssertLessThanOrEqual(TaskCardExcerpt.text(String(repeating: "description ", count: 5000)).count, 900)
        XCTAssertEqual(TaskCardExcerpt.text("```swift\nprint(1)\n```"), "print(1)")
    }
}
