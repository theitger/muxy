import XCTest
@testable import muxy

final class QuorumRunTests: XCTestCase {
    private var cache: String!

    override func setUpWithError() throws {
        cache = NSTemporaryDirectory() + "muxy-quorum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: cache)
    }

    private func write(_ path: String, _ text: String, modified: Date? = nil) throws {
        let file = cache + "/" + path
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file) }
    }

    private func at(_ stamp: String) -> Date { QuorumRun.stamp(of: "x-" + stamp)! }

    private let comment = """
    ## Summary

    Two defects in the former-staff flow.

    ## Blockers

    None.

    ## Critical

    - `backend/handlers_former.go:45-48` — Keep the `role` filter for
      former staff.

    - `frontend/route.ts:12` — Preserve IDs as strings.

    ## Suggestions

    - Add retired staff to the seed.

    ## Questions

    None.
    """

    func testParsesTheReviewComment() {
        let parsed = QuorumRun.parse(comment)
        XCTAssertEqual(parsed.summary, "Two defects in the former-staff flow.")
        XCTAssertEqual(parsed.findings.count, 3)
        XCTAssertEqual(parsed.findings[0], .init(severity: .critical, location: "backend/handlers_former.go:45-48",
                                                 text: "Keep the `role` filter for former staff."))
        XCTAssertEqual(parsed.findings[2], .init(severity: .suggestion, location: nil, text: "Add retired staff to the seed."))
    }

    func testABabysitIsItsReviewsAndFixesInOrder() throws {
        let run = "babysit/o-r-pr-7-20261019-224308"
        try write(run + "/progress.json", """
        {"repo":"o/r","number":7,"started_at":"\(ISO8601DateFormatter().string(from: at("20261019-224308")))",
         "round":2,"max_iter":12,"phase":"description","ci":"green",
         "review_model":{"model":"luna","effort":"medium"},"fix_model":{"model":"terra","effort":"high"}}
        """)
        try write(run + "/logs/rounds.log", """
        Review fix round 1:
        7981f2b507 fix(staff): harden former list

        Test fix 1:
        1441c99b1a fix(staff): scope guest markers
        """)
        try write(run + "/logs/fix-round-1.log", "…", modified: at("20261019-230000"))
        try write(run + "/logs/test-fix-1.log", "…", modified: at("20261019-231000"))
        try write(run + "/logs/tests-1.log", "…", modified: at("20261019-230500"))
        try write(run + "/logs/ci-last.log", "…", modified: at("20261020-010000"))
        try write(run + "/messages/fix-round-1.md", "Fixed both.\n\n- IDs are strings now.")
        try write(run + "/messages/fix-round-1-dispute.md", "The seed finding is intended.")
        for (stamp, critical) in [("20261019-224311", 2), ("20261020-003000", 0)] {
            let review = "reviews/o-r-pr-7-\(stamp)"
            try write(review + "/target.json", #"{"schema":2,"repo":"o/r","number":7}"#)
            try write(review + "/output/final-pr-comment.md", critical > 0 ? comment : "## Summary\n\nClean.\n")
            try write(review + "/output/findings.json", """
            {"schema":1,"head_sha":"abcdef0123456789","blockers":0,"critical":\(critical),"suggestions":0,
             "reviewers_requested":6,"reviewers_succeeded":6,"comment_file":"\(cache!)/\(review)/output/final-pr-comment.md"}
            """)
        }
        // Another PR's review, and one from before the run: not its own.
        try write("reviews/o-r-pr-8-20261019-230000/output/findings.json", #"{"schema":1,"critical":9}"#)
        try write("reviews/o-r-pr-7-20261018-100000/output/findings.json", #"{"schema":1,"critical":9}"#)

        let status = QuorumStatus(kind: .babysit, key: "o/r#7", running: false, outcome: "converged",
                                  date: at("20261020-011000"), runDirectory: cache + "/" + run)
        let loaded = try XCTUnwrap(QuorumRun.load(status, cache: cache))
        XCTAssertEqual(loaded.steps.map(\.kind), [.review, .fix, .testFix, .review, .ci, .end])
        XCTAssertEqual(loaded.rounds, 2)
        XCTAssertEqual(loaded.steps[0].critical, 2)
        XCTAssertEqual(loaded.steps[0].findings.count, 3)
        XCTAssertEqual(loaded.steps[0].head, "abcdef0123")
        XCTAssertEqual(loaded.steps[1].commits, ["7981f2b507 fix(staff): harden former list"])
        XCTAssertEqual(loaded.steps[1].summary, "Fixed both.\n\n- IDs are strings now.")
        XCTAssertEqual(loaded.steps[1].dispute, "The seed finding is intended.")
        XCTAssertEqual(loaded.steps[2].commits, ["1441c99b1a fix(staff): scope guest markers"])
        XCTAssertEqual(loaded.steps[3].number, 2)
        XCTAssertEqual(loaded.steps[3].ok, true)
        XCTAssertEqual(loaded.steps[4].ok, true)
        XCTAssertEqual(loaded.reviewModel, "luna · medium")
        XCTAssertEqual(loaded.latestReview?.open, 0)
        // Opens on how it ended: nothing is open any more.
        XCTAssertEqual(QuorumRunView.focus(loaded)?.kind, .end)
    }

    /// quorum ends clean when the fixing agent argues a finding away: the
    /// view and the card say so instead of calling it fixed.
    func testAFindingArguedAwayIsDisputedNotFixed() throws {
        let run = "babysit/o-r-pr-5-20261019-194425"
        try write(run + "/progress.json", #"{"repo":"o/r","number":5,"ci":"green"}"#)
        try write(run + "/logs/fix-round-1.log", "…", modified: at("20261019-195100"))
        try write(run + "/logs/fix-round-1-dispute-1.log", "…", modified: at("20261019-195000"))
        try write(run + "/messages/fix-round-1.md", "No change.")
        try write(run + "/messages/fix-round-1-dispute-1.md", "Out of scope for this PR.")
        try write("reviews/o-r-pr-5-20261019-194430/output/findings.json", #"{"schema":1,"blockers":1}"#)
        try write("history.jsonl", #"{"key":"o/r#5","kind":"babysit","outcome":"converged","blockers":1,"ended_at":"2026-10-19T20:08:34+02:00","run_dir":"\#(cache!)/\#(run)"}"# + "\n")

        let status = try XCTUnwrap(Quorum.finished(at: cache + "/history.jsonl").first)
        XCTAssertTrue(status.disputed)
        XCTAssertEqual(status.summary, L("quorum: clean, findings disputed"))
        let loaded = try XCTUnwrap(QuorumRun.load(status, cache: cache))
        XCTAssertEqual(loaded.steps.map(\.kind), [.review, .fix, .end], "the dispute's own log is no step")
        XCTAssertEqual(loaded.steps[1].dispute, "Out of scope for this PR.")
        XCTAssertEqual(loaded.resolved.fixed, 0)
        XCTAssertEqual(loaded.resolved.disputed, 1)
        XCTAssertEqual(QuorumRunView.subtitle(loaded.steps[1]), L("disputed, no commit"))
    }

    func testAReviewOnlyRunIsOneReview() throws {
        let review = "reviews/o-r-pr-9-20261020-091147"
        try write(review + "/output/findings.json", #"{"schema":1,"blockers":1,"critical":0,"suggestions":2}"#)
        let status = QuorumStatus(kind: .review, key: "o/r#9", running: false, blockers: 1, outcome: "ok",
                                  date: Date(), runDirectory: cache + "/" + review)
        let loaded = try XCTUnwrap(QuorumRun.load(status, cache: cache))
        XCTAssertEqual(loaded.steps.map(\.kind), [.review, .end])
        XCTAssertEqual(loaded.steps[0].blockers, 1)
        XCTAssertEqual(QuorumRunView.focus(loaded)?.kind, .review, "a finding still open comes first")
    }

    func testFolderNames() {
        XCTAssertEqual(QuorumRun.prefix(of: "/c/babysit/moto-nrw-project-phoenix-pr-4399-20261019-224308"),
                       "moto-nrw-project-phoenix-pr-4399-")
        XCTAssertNotNil(QuorumRun.stamp(of: "/c/reviews/o-r-pr-1-20261020-091147"))
        XCTAssertNil(QuorumRun.stamp(of: "/c/reviews/whatever"))
    }

    func testSaysWhenQuorumIsNewerOrWritesAnotherSchema() throws {
        XCTAssertTrue(QuorumCompat.newer("1.17.0", than: "1.16.0"))
        XCTAssertTrue(QuorumCompat.newer("2.0", than: "1.16.0"))
        XCTAssertFalse(QuorumCompat.newer("1.16.0", than: "1.16.0"))
        XCTAssertFalse(QuorumCompat.newer("1.15.5", than: "1.16.0"))
        XCTAssertFalse(QuorumCompat.newer("1.16.0-dev+3d85e2a.dirty", than: "1.16.0"))
        XCTAssertTrue(QuorumCompat.supportsDivergenceScan("1.10.0"))
        XCTAssertFalse(QuorumCompat.supportsDivergenceScan("1.9.9"))
        XCTAssertFalse(QuorumCompat.supportsDivergenceScan(nil))

        XCTAssertNil(QuorumCompat.warning(for: nil, installed: QuorumCompat.tested))
        XCTAssertNotNil(QuorumCompat.warning(for: nil, installed: "1.17.0"))
        try write("r/output/findings.json", #"{"schema":2}"#)
        XCTAssertNotNil(QuorumCompat.warning(for: cache + "/r", installed: QuorumCompat.tested))
    }

    func testLegacyBabysitUsesTheRetainedCheckoutHead() throws {
        let repo = try TempRepo()
        let run = cache + "/legacy-babysit"
        try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: run + "/worktree", withDestinationPath: repo.root)

        XCTAssertEqual(Quorum.acceptedHead(kind: .babysit, in: run), try repo.head().lowercased())
    }
}
