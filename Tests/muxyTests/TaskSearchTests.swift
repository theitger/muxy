import XCTest
@testable import muxy

final class TaskSearchTests: XCTestCase {
    func testAllWordsCanMatchDifferentFieldsIgnoringCaseAndAccents() {
        XCTAssertTrue(TaskSearch.matches("MUXY übersicht", fields: ["Ubersicht verbessern", "theitger/muxy"]))
        XCTAssertTrue(TaskSearch.matches("  muxy \n priority:high  ", fields: ["theitger/muxy", "priority:high"]))
        XCTAssertFalse(TaskSearch.matches("muxy missing", fields: ["theitger/muxy", "priority:high"]))
    }

    func testIssueReferencesAndEveryLabelAreSearchable() {
        let issue = Issue(repo: "owner/muxy", number: 42, title: "Fix terminal", url: "", state: "OPEN",
                          labels: ["a", "b", "c", "macbook", "accessibility"])
        XCTAssertTrue(TaskSearch.matches("#42", fields: TaskSearch.fields(issue)))
        XCTAssertTrue(TaskSearch.matches("42 macbook", fields: TaskSearch.fields(issue)))
        XCTAssertTrue(TaskSearch.matches("ACCESSIBILITY", fields: TaskSearch.fields(issue)))
        XCTAssertFalse(TaskSearch.matches("#43", fields: TaskSearch.fields(issue)))
    }

    func testBranchAndEmptyQueries() {
        XCTAssertTrue(TaskSearch.matches("fix/header", fields: ["Fix terminal", "fix/header-height"]))
        XCTAssertTrue(TaskSearch.matches("", fields: []))
        XCTAssertTrue(TaskSearch.matches(" \n\t ", fields: []))
        XCTAssertFalse(TaskSearch.matches("unknown", fields: []))
    }
}
