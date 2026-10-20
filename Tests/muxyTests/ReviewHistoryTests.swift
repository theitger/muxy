import XCTest
@testable import muxy

final class ReviewHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ number: Int, days: Double = 0, running: Bool = false, outcome: String? = "converged") -> QuorumStatus {
        QuorumStatus(kind: .babysit, key: "owner/repo#\(number)", running: running,
                     outcome: outcome, date: now.addingTimeInterval(-days * 86400))
    }

    func testSuccessfulReviewsStayActiveUntilThePRCloses() {
        let groups = ReviewHistory.group([run(1), run(2), run(3)],
                                         states: ["owner/repo#1": .open, "owner/repo#2": .merged, "owner/repo#3": .closed], now: now)
        XCTAssertEqual(groups.active.map(\.key), ["owner/repo#1"])
        XCTAssertEqual(groups.completed.map(\.key), ["owner/repo#2", "owner/repo#3"])
    }

    func testArchiveCutoffDoesNotHideOldOpenOrUnknownPRs() {
        let groups = ReviewHistory.group([run(1, days: 30), run(2, days: 30.001), run(3, days: 90), run(4, days: 90)],
                                         states: ["owner/repo#1": .merged, "owner/repo#2": .closed, "owner/repo#3": .open], now: now)
        XCTAssertEqual(groups.active.map(\.key), ["owner/repo#3", "owner/repo#4"])
        XCTAssertEqual(groups.completed.map(\.key), ["owner/repo#1"])
    }

    func testRunningFirstThenNewestAndMergedEvenIfRunStillLooksActive() {
        let groups = ReviewHistory.group([run(1), run(2, days: 2, running: true), run(3, days: 1), run(4, running: true)],
                                         states: ["owner/repo#4": .merged], now: now)
        XCTAssertEqual(groups.active.map(\.key), ["owner/repo#2", "owner/repo#1", "owner/repo#3"])
        XCTAssertEqual(groups.completed.map(\.key), ["owner/repo#4"])
    }

    func testPartialGraphQLFailureDoesNotTreatUnknownPRAsCompleted() {
        let result = ReviewHistory.parse("""
        {"data":{"r0":{"pullRequest":{"state":"MERGED"}},"r1":null,"r2":{"pullRequest":{"state":"OPEN"}}},
         "errors":[{"message":"Could not resolve repository"}]}
        """, keys: ["owner/repo#1", "private/repo#2", "owner/repo#3"])
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.states, ["owner/repo#1": .merged, "owner/repo#3": .open])
        let groups = ReviewHistory.group([run(1), QuorumStatus(kind: .review, key: "private/repo#2", running: false, date: now)], states: result.states, now: now)
        XCTAssertEqual(groups.active.map(\.key), ["private/repo#2"])
    }

    func testBranchReviewsHaveTheirOwnLifecycleWithoutAFakePR() {
        let recent = QuorumStatus(kind: .review, key: "owner/repo#branch:recent", running: false, date: now)
        let old = QuorumStatus(kind: .review, key: "owner/repo#branch:old", running: false, date: now.addingTimeInterval(-31 * 86400))
        let running = QuorumStatus(kind: .review, key: "owner/repo#branch:running", running: true, date: old.date)
        let groups = ReviewHistory.group([recent, old, running], states: [:], now: now)
        XCTAssertEqual(groups.active.map(\.key), [running.key])
        XCTAssertEqual(groups.completed.map(\.key), [recent.key])
        XCTAssertFalse(ReviewHistory.load(keys: [old.key]).incomplete)
    }

    func testMalformedOrUnexpectedResponsesStayUnknown() {
        for response in ["not JSON", "{}", "{\"data\":{\"r0\":{\"pullRequest\":null}}}",
                         "{\"data\":{\"r0\":{\"pullRequest\":{\"state\":\"FUTURE_STATE\"}}}}"] {
            let lookup = ReviewHistory.parse(response, keys: ["owner/repo#1"])
            XCTAssertTrue(lookup.incomplete)
            XCTAssertTrue(lookup.states.isEmpty)
        }
    }
}
