import XCTest
@testable import muxy

final class WorkStateTests: XCTestCase {
    func testSnapshotOfACleanCheckoutIsHead() throws {
        let repo = try TempRepo()
        let snapshot = try XCTUnwrap(WorkState.snapshot(of: repo.root))
        XCTAssertEqual(snapshot.commit, try repo.head())
    }

    func testSnapshotTakesChangesAndNewFilesButLeavesTheIndexAlone() throws {
        let repo = try TempRepo()
        try repo.write("README.md", "changed\n")
        try repo.write("new.txt", "new\n")
        try repo.write(".gitignore", "ignored.txt\n")
        try repo.write("ignored.txt", "secret\n")
        let snapshot = try XCTUnwrap(WorkState.snapshot(of: repo.root))
        XCTAssertNotEqual(snapshot.commit, try repo.head())
        XCTAssertEqual(try repo.git("show", snapshot.commit + ":README.md"), "changed")
        XCTAssertEqual(try repo.git("show", snapshot.commit + ":new.txt"), "new")
        XCTAssertThrowsError(try repo.git("show", snapshot.commit + ":ignored.txt"))
        // Nothing staged, nothing committed.
        XCTAssertEqual(try repo.git("diff", "--cached", "--name-only"), "")
        XCTAssertEqual(try repo.git("status", "--porcelain").split(separator: "\n").count, 3)
    }

    func testConflictsBetweenTwoWorktrees() throws {
        let repo = try TempRepo()
        try repo.write("shared.txt", "one\ntwo\nthree\n")
        try repo.commit("Shared")
        let a = try repo.addWorktree("a", branch: "a")
        let b = try repo.addWorktree("b", branch: "b")
        let c = try repo.addWorktree("c", branch: "c")
        try repo.write("shared.txt", "one\nTWO from a\nthree\n", in: a)
        try repo.write("shared.txt", "one\nTWO from b\nthree\n", in: b)
        try repo.write("other.txt", "c\n", in: c)
        let sa = try XCTUnwrap(WorkState.snapshot(of: a))
        let sb = try XCTUnwrap(WorkState.snapshot(of: b))
        let sc = try XCTUnwrap(WorkState.snapshot(of: c))
        XCTAssertEqual(WorkState.conflicts(between: sa.commit, and: sb.commit, in: repo.root), ["shared.txt"])
        XCTAssertEqual(WorkState.conflicts(between: sa.commit, and: sc.commit, in: repo.root), [])
    }

    func testChangedFiles() throws {
        let repo = try TempRepo()
        let base = try repo.head()
        try repo.write("src/a.swift", "a\n")
        let snapshot = try XCTUnwrap(WorkState.snapshot(of: repo.root))
        XCTAssertEqual(WorkState.changedFiles(from: base, to: snapshot.commit, in: repo.root), ["src/a.swift"])
    }
}

final class CheckpointTests: XCTestCase {
    func testRecordsOnlyWhenFilesChange() throws {
        let repo = try TempRepo()
        XCTAssertNotNil(Checkpoints.record(.before, label: "Fix the login", in: repo.root))
        XCTAssertNil(Checkpoints.record(.after, label: "Nothing", in: repo.root))
        try repo.write("README.md", "edited\n")
        let after = try XCTUnwrap(Checkpoints.record(.after, label: "Edited the readme\nmore", in: repo.root))
        let list = Checkpoints.list(in: repo.root)
        XCTAssertEqual(list.map(\.moment), [.after, .before])
        XCTAssertEqual(list.first?.label, "Edited the readme")
        XCTAssertEqual(list.first?.commit, after.commit)
        // Not on any branch, not in the log.
        XCTAssertEqual(try repo.git("log", "--oneline").split(separator: "\n").count, 1)
    }

    func testRestorePutsFilesBackAndCanBeUndone() throws {
        let repo = try TempRepo()
        let before = try XCTUnwrap(Checkpoints.record(.before, label: "Task", in: repo.root))
        try repo.write("README.md", "agent was here\n")
        try repo.write("added.txt", "new\n")
        XCTAssertTrue(Checkpoints.restore(before, in: repo.root))
        XCTAssertEqual(repo.read("README.md"), "hello\n")
        XCTAssertFalse(repo.exists(repo.path("added.txt")))
        XCTAssertEqual(try repo.git("status", "--porcelain"), "")
        // The state right before going back is a checkpoint too.
        let undo = try XCTUnwrap(Checkpoints.list(in: repo.root).first)
        XCTAssertTrue(Checkpoints.restore(undo, in: repo.root))
        XCTAssertEqual(repo.read("README.md"), "agent was here\n")
        XCTAssertEqual(repo.read("added.txt"), "new\n")
    }

    func testCheckoutsKeepTheirOwnCheckpoints() throws {
        let repo = try TempRepo()
        let wt = try repo.addWorktree("feature", branch: "feature")
        try repo.write("x.txt", "x\n", in: wt)
        XCTAssertNotNil(Checkpoints.record(.after, label: "x", in: wt))
        XCTAssertEqual(Checkpoints.list(in: wt).count, 1)
        XCTAssertEqual(Checkpoints.list(in: repo.root).count, 0)
        Checkpoints.forget(wt, root: repo.root)
        XCTAssertEqual(Checkpoints.list(in: wt).count, 0)
    }
}

final class ProofTests: XCTestCase {
    func testParsesChecks() {
        let checks = ProofCheck.parse("""
        check.frontend.run cd frontend && pnpm lint
        check.frontend.paths frontend/, packages/ui
        check.backend.run make test
        check.backend.auto false
        check.empty.paths x/
        """)
        XCTAssertEqual(checks.map(\.name), ["frontend", "backend"])
        XCTAssertEqual(checks[0].paths, ["frontend/", "packages/ui"])
        XCTAssertTrue(checks[0].auto)
        XCTAssertFalse(checks[1].auto)
    }

    func testAppliesByPath() {
        let check = ProofCheck(name: "fe", command: "true", paths: ["frontend/"])
        XCTAssertTrue(check.applies(to: ["frontend/src/a.ts"]))
        XCTAssertFalse(check.applies(to: ["backend/main.go", "frontend.md"]))
        XCTAssertTrue(ProofCheck(name: "all", command: "true").applies(to: []))
    }

    func testLoadsChecksFromWtconfig() throws {
        let repo = try TempRepo()
        try repo.write(".wtconfig", """
        [wt]
            base = main
        [check "unit"]
            run = swift test
            paths = Sources/
        """)
        XCTAssertEqual(ProofCheck.load(root: repo.root), [ProofCheck(name: "unit", command: "swift test", paths: ["Sources/"])])
    }

    func testProveRunsRelevantChecksAndCaches() throws {
        let repo = try TempRepo()
        try repo.write("src/a.txt", "a\n")
        let checks = [
            ProofCheck(name: "pass", command: "test -f src/a.txt", paths: ["src/"]),
            ProofCheck(name: "fail", command: "echo broken; exit 3"),
            ProofCheck(name: "docs", command: "exit 1", paths: ["docs/"])
        ]
        let runner = Proofs.Runner()
        let result = try XCTUnwrap(Proofs.prove(checkout: repo.root, root: repo.root, checks: checks, runner: runner) { _, _, _ in })
        XCTAssertEqual(result.entries.map(\.outcome), [.passed, .failed, .skipped])
        XCTAssertEqual(result.verdict, .failed)
        XCTAssertTrue(result.entries[1].tail.contains("broken"))
        // A failure is never remembered: the same files run again.
        try FileManager.default.removeItem(atPath: repo.path("src/a.txt"))
        try repo.write("src/a.txt", "a\n")
        let again = try XCTUnwrap(Proofs.prove(checkout: repo.root, root: repo.root, checks: checks, runner: runner) { _, _, _ in })
        XCTAssertEqual(again.entries.map(\.outcome), [.passed, .failed, .skipped])
    }
}

final class SnapshotStabilityTests: XCTestCase {
    func testSameFilesSameCommit() throws {
        let repo = try TempRepo()
        try repo.write("README.md", "changed\n")
        let first = try XCTUnwrap(WorkState.snapshot(of: repo.root))
        Thread.sleep(forTimeInterval: 1.1)
        let second = try XCTUnwrap(WorkState.snapshot(of: repo.root))
        XCTAssertEqual(first.commit, second.commit)
    }
}
