import XCTest
@testable import muxy

@MainActor
final class WorkTests: XCTestCase {
    override func setUp() {
        try? FileManager.default.removeItem(atPath: WorkLedger.file)
    }

    func testAFactIsWrittenDownOnceAndTheWorkKeptAcrossLaunches() {
        let ledger = WorkLedger()
        let fact = Evidence(kind: .checks, date: Date(), text: "Checks passed: backend", ok: true, ref: "abc")
        ledger.note(fact, root: "/r", branch: "feat/x")
        ledger.note(fact, root: "/r", branch: "feat/x")
        XCTAssertEqual(ledger.items[WorkItem.key(root: "/r", branch: "feat/x")]?.evidence.count, 1)

        // The next launch reads it back and still doesn't write it twice.
        let again = WorkLedger()
        XCTAssertEqual(again.items.count, 1)
        again.note(fact, root: "/r", branch: "feat/x")
        XCTAssertEqual(again.items.values.first?.evidence.count, 1)
    }

    func testDroppedOrEndedWorkIsOffTheBoard() {
        var item = WorkItem(root: "/r", branch: "b", title: "t", created: Date(), touched: Date())
        XCTAssertTrue(item.isOpen)
        item.prState = "merged"
        XCTAssertFalse(item.isOpen)
        item.prState = "open"
        item.dropped = true
        XCTAssertFalse(item.isOpen)
    }

    func testBaseBranchesAreNotWork() {
        XCTAssertTrue(WorkLedger.isBase("main"))
        XCTAssertTrue(WorkLedger.isBase("development"))
        XCTAssertFalse(WorkLedger.isBase("feat/3401-fix"))
    }

    func testTheReportSaysWhatWasCheckedAndReviewed() {
        var item = WorkItem(root: "/r", branch: "b", title: "t", created: Date(), touched: Date())
        item.evidence = [
            Evidence(kind: .checks, date: Date(timeIntervalSince1970: 1), text: "Checks failed: backend", ok: false, ref: "old"),
            Evidence(kind: .checks, date: Date(timeIntervalSince1970: 2), text: "Checks passed: backend, frontend", ok: true, ref: "new"),
            Evidence(kind: .quorum, date: Date(timeIntervalSince1970: 3), text: "quorum: clean, 2 fixed", ok: true),
        ]
        let report = WorkLedger.report(item)
        XCTAssertTrue(report.contains("✅ Checks passed: backend, frontend (`new`)"), "the latest checks count")
        XCTAssertFalse(report.contains("old"))
        XCTAssertTrue(report.contains("quorum: clean, 2 fixed"))
        XCTAssertTrue(report.contains(L("No collisions with other work")))
    }
}
