import XCTest
@testable import muxy

final class DiffParseTests: XCTestCase {
    func testParsesFilesHunksAndNumbers() {
        let files = Diffs.parse("""
        diff --git a/src/a.swift b/src/a.swift
        index 1111111..2222222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,3 +1,4 @@ struct A {
         one
        -two
        +TWO
        +three
         four
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +++ looks like a header but is a line
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        """)
        XCTAssertEqual(files.map(\.path), ["src/a.swift", "new.txt", "new name.txt"])
        let a = files[0]
        XCTAssertEqual(a.kind, .modified)
        XCTAssertEqual(a.additions, 2)
        XCTAssertEqual(a.deletions, 1)
        XCTAssertEqual(a.lines.map(\.role), [.hunk, .context, .removed, .added, .added, .context])
        XCTAssertEqual(a.lines[2].old, 2)
        XCTAssertEqual(a.lines[3].new, 2)
        XCTAssertEqual(a.lines[5].old, 3)
        XCTAssertEqual(a.lines[5].new, 4)
        XCTAssertEqual(files[1].kind, .added)
        XCTAssertEqual(files[1].lines.last?.text, "++ looks like a header but is a line")
        XCTAssertEqual(files[2].kind, .renamed)
        XCTAssertEqual(files[2].oldPath, "old name.txt")
    }

    func testLoadsARealDiff() throws {
        let repo = try TempRepo()
        let base = try repo.head()
        try repo.write("README.md", "hello\nworld\n")
        let now = try XCTUnwrap(WorkState.snapshot(of: repo.root))
        let files = Diffs.load(from: base, to: now.commit, in: repo.root)
        XCTAssertEqual(files.first?.path, "README.md")
        XCTAssertEqual(files.first?.additions, 1)
    }

    func testReviewMessageQuotesEachLine() {
        let text = ReviewMessage.compose([
            ReviewComment(path: "a.go", line: 12, removed: false, code: "  x := 1", text: "Name it count."),
            ReviewComment(path: "b.go", line: 3, removed: true, code: "return nil", text: "Keep this.")
        ])
        XCTAssertTrue(text.contains("1. a.go:12\n   » x := 1\n   Name it count."))
        XCTAssertTrue(text.contains("2. b.go:3 (a line you removed)"))
    }
}

final class QuorumTests: XCTestCase {
    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "muxy-quorum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path + "/output", withIntermediateDirectories: true)
        return path
    }

    func testReadsARunningBabysit() throws {
        let dir = try folder()
        try """
        {"pid":1,"repo":"o/r","number":42,"branch":"b","round":2,"phase":"fix","blockers":1,"updated_at":"2026-10-19T11:35:04.967115+02:00"}
        """.write(toFile: dir + "/progress.json", atomically: true, encoding: .utf8)
        // Our own pid: certainly alive.
        try "\(getpid())".write(toFile: dir + "/run.pid", atomically: true, encoding: .utf8)
        let status = try XCTUnwrap(Quorum.run(in: dir, kind: .babysit, modified: Date()))
        XCTAssertEqual(status.key, "o/r#42")
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.round, 2)
        XCTAssertEqual(status.blockers, 1)
        XCTAssertFalse(status.isClean)
    }

    func testReadsAFinishedReview() throws {
        let dir = try folder()
        try #"{"repo":"o/r","number":7}"#.write(toFile: dir + "/target.json", atomically: true, encoding: .utf8)
        try #"{"blockers":0,"critical":0,"suggestions":2,"comment_file":"/x/final.md"}"#
            .write(toFile: dir + "/output/findings.json", atomically: true, encoding: .utf8)
        try "999999".write(toFile: dir + "/run.pid", atomically: true, encoding: .utf8)
        let status = try XCTUnwrap(Quorum.run(in: dir, kind: .review, modified: Date()))
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(status.suggestions, 2)
        XCTAssertEqual(status.report, "/x/final.md")
    }

    func testADeadRunWithoutOutputIsNothing() throws {
        let dir = try folder()
        try #"{"repo":"o/r","number":7}"#.write(toFile: dir + "/target.json", atomically: true, encoding: .utf8)
        try "999999".write(toFile: dir + "/run.pid", atomically: true, encoding: .utf8)
        XCTAssertNil(Quorum.run(in: dir, kind: .review, modified: Date()))
    }
}

final class InventoryTests: XCTestCase {
    func testOwnersAndFinishedWork() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let mine = try repo.addWorktree("mine", branch: "mine")
        try repo.write("work.txt", "unsaved\n", in: mine)
        let empty = try repo.addWorktree("empty", branch: "empty")
        let claude = (repo.root as NSString).appendingPathComponent(".claude/worktrees/agent-1")
        try repo.git("worktree", "add", "--quiet", "-b", "agent-1", claude, "HEAD")
        let found = Inventory.scan(roots: [repo.root])
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0) })
        XCTAssertEqual(byPath[repo.root]?.owner, .main)
        XCTAssertEqual(byPath[mine]?.owner, .muxy)
        XCTAssertEqual(byPath[claude]?.owner, .claude)
        XCTAssertEqual(byPath[mine]?.changes, 1)
        XCTAssertEqual(byPath[mine]?.isFinished, false)
        XCTAssertEqual(byPath[empty]?.isFinished, true)
        XCTAssertEqual(byPath[repo.root]?.isFinished, false)
    }

    func testRemovesAFinishedWorktreeAndItsBranch() throws {
        let repo = try TempRepo()
        let other = (repo.base as NSString).appendingPathComponent("by-hand")
        try repo.git("worktree", "add", "--quiet", "-b", "by-hand", other, "HEAD")
        let info = try XCTUnwrap(Inventory.scan(roots: [repo.root]).first { $0.path == other })
        XCTAssertEqual(info.owner, .other)
        XCTAssertTrue(Inventory.remove(info))
        XCTAssertFalse(repo.exists(other))
        XCTAssertThrowsError(try repo.git("rev-parse", "--verify", "refs/heads/by-hand"))
    }

    func testNeverRemovesTheMainCheckout() throws {
        let repo = try TempRepo()
        let main = try XCTUnwrap(Inventory.scan(roots: [repo.root]).first)
        XCTAssertFalse(Inventory.remove(main))
        XCTAssertTrue(repo.exists(repo.root))
    }

    func testComposeProjectNameComesFromEnv() throws {
        let repo = try TempRepo(name: "My App")
        XCTAssertEqual(Inventory.projectName(of: repo.root), "my_app")
        try repo.write(".env", "COMPOSE_PROJECT_NAME=shared\n")
        XCTAssertEqual(Inventory.projectName(of: repo.root), "shared")
    }
}

final class RadarTests: XCTestCase {
    func testFindsCollisionsBetweenSessionsAndWithTheBase() throws {
        let repo = try TempRepo()
        try repo.write("shared.txt", "one\ntwo\nthree\n")
        try repo.commit("Shared")
        try repo.addOrigin()
        let a = try repo.addWorktree("a", branch: "a")
        let b = try repo.addWorktree("b", branch: "b")
        try repo.write("shared.txt", "one\nA\nthree\n", in: a)
        try repo.write("shared.txt", "one\nB\nthree\n", in: b)
        // main moves on in the same line: both now conflict with it.
        try repo.write("shared.txt", "one\nMAIN\nthree\n")
        try repo.commit("Main moves")
        try repo.git("push", "--quiet", "origin", "main")
        try repo.git("fetch", "--quiet", "origin")
        let found = Radar.scan(root: repo.root, checkouts: [a, b], memo: Radar.Memo())
        let forA = try XCTUnwrap(found[a])
        XCTAssertTrue(forA.contains { $0.other == b && $0.files == ["shared.txt"] })
        XCTAssertTrue(forA.contains { $0.withBase && $0.other == "origin/main" })
        XCTAssertTrue(found[b]?.contains { $0.other == a } == true)
    }

    func testQuietWhenWorkDoesNotOverlap() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let a = try repo.addWorktree("a", branch: "a")
        let b = try repo.addWorktree("b", branch: "b")
        try repo.write("a.txt", "a\n", in: a)
        try repo.write("b.txt", "b\n", in: b)
        XCTAssertTrue(Radar.scan(root: repo.root, checkouts: [a, b], memo: Radar.Memo()).isEmpty)
    }
}

final class ReviewFixTests: XCTestCase {
    func testFailuresAreNotCachedAndCommandsCount() throws {
        let repo = try TempRepo()
        try repo.write("x.txt", "\(UUID())\n")
        let runner = Proofs.Runner()
        let failing = [ProofCheck(name: "t", command: "exit 1")]
        XCTAssertEqual(Proofs.prove(checkout: repo.root, root: repo.root, checks: failing, runner: runner) { _, _, _ in }?.verdict, .failed)
        // Same files, the command fixed: it runs again and passes.
        let fixed = [ProofCheck(name: "t", command: "true")]
        XCTAssertEqual(Proofs.prove(checkout: repo.root, root: repo.root, checks: fixed, runner: runner) { _, _, _ in }?.verdict, .passed)
        // A pass is remembered only for its own command.
        let other = [ProofCheck(name: "t", command: "exit 2")]
        XCTAssertEqual(Proofs.prove(checkout: repo.root, root: repo.root, checks: other, runner: runner) { _, _, _ in }?.verdict, .failed)
    }

    func testQuorumSucceedsOnlyWhenItSaysSo() {
        var status = QuorumStatus(kind: .babysit, key: "o/r#1", running: false, date: Date())
        XCTAssertFalse(status.succeeded, "no outcome yet")
        status.outcome = "failed"
        XCTAssertFalse(status.succeeded, "failed with zero counts")
        status.outcome = "converged"
        XCTAssertTrue(status.succeeded)
        status.blockers = 1
        XCTAssertFalse(status.succeeded)
    }

    func testUnknownGitStateIsNeverFinished() {
        let info = WorktreeInfo(path: "/x", root: "/r", owner: .other, changes: -1, ahead: 0)
        XCTAssertFalse(info.isFinished)
        let behind = WorktreeInfo(path: "/x", root: "/r", owner: .other, changes: 0, ahead: -1)
        XCTAssertFalse(behind.isFinished)
        var merged = WorktreeInfo(path: "/x", root: "/r", owner: .other, changes: 0, ahead: 3)
        merged.prState = .merged
        XCTAssertFalse(merged.isFinished, "merged PR on the same name, but not this work")
        merged.mergedHere = true
        XCTAssertTrue(merged.isFinished)
    }

    func testRunnerSurvivesAShellThatIgnoresTerm() throws {
        // A cancel must kill the tree and come back, never crash.
        let runner = Proofs.Runner()
        let log = NSTemporaryDirectory() + "muxy-term-\(UUID()).log"
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { runner.cancel("k") }
        let outcome = runner.run("trap '' TERM; sleep 30", in: NSTemporaryDirectory(), log: log, key: "k")
        XCTAssertEqual(outcome, .cancelled)
    }
}
