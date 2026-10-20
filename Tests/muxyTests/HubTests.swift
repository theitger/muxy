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
        let reviewed = String(repeating: "a", count: 40)
        try #"{"repo":"o/r","number":7}"#.write(toFile: dir + "/target.json", atomically: true, encoding: .utf8)
        try #"{"head_sha":"\#(reviewed)","blockers":0,"critical":0,"suggestions":2,"comment_file":"/x/final.md"}"#
            .write(toFile: dir + "/output/findings.json", atomically: true, encoding: .utf8)
        try "999999".write(toFile: dir + "/run.pid", atomically: true, encoding: .utf8)
        let status = try XCTUnwrap(Quorum.run(in: dir, kind: .review, modified: Date()))
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(status.headSHA, reviewed)
        XCTAssertEqual(status.suggestions, 2)
        XCTAssertEqual(status.report, "/x/final.md")
    }

    func testOnlyARecordedCommitCanCoverALanding() throws {
        let dir = try folder()
        let reviewed = String(repeating: "a", count: 40)
        let changed = String(repeating: "b", count: 40)
        try "{\"head_sha\":\"\(reviewed)\"}"
            .write(toFile: dir + "/output/findings.json", atomically: true, encoding: .utf8)
        var status = QuorumStatus(kind: .review, key: "o/r#7", running: false,
                                  outcome: "ok", date: Date(), runDirectory: dir)
        status.headSHA = Quorum.acceptedHead(kind: .review, in: dir)
        XCTAssertTrue(Landing.reviewCovers(status, head: reviewed))
        XCTAssertFalse(Landing.reviewCovers(status, head: changed), "a pushed commit after review needs a new run")
        XCTAssertEqual(status.summary(for: changed), L("quorum: review outdated"))
        XCTAssertFalse(Landing.reviewCovers(status, head: nil))
        status.headSHA = nil
        XCTAssertFalse(Landing.reviewCovers(status, head: reviewed), "missing artifacts fail closed")

        try "{\"final_head\":\"\(changed)\"}"
            .write(toFile: dir + "/divergence-trace.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(Quorum.acceptedHead(kind: .babysit, in: dir), changed,
                       "babysit can fix the reviewed commit before it converges")
        try #"{"final_head":"not-a-commit"}"#
            .write(toFile: dir + "/divergence-trace.json", atomically: true, encoding: .utf8)
        XCTAssertNil(Quorum.acceptedHead(kind: .babysit, in: dir))
    }

    func testFinishedHistoryCarriesTheAcceptedHeadIntoLanding() throws {
        let dir = try folder()
        let old = String(repeating: "a", count: 40)
        let final = String(repeating: "b", count: 40)
        try "{\"final_head\":\"\(final)\",\"rounds\":[{\"reviewed_sha\":\"\(old)\"}]}"
            .write(toFile: dir + "/divergence-trace.json", atomically: true, encoding: .utf8)
        let history = dir + "/history.jsonl"
        let record: [String: Any] = [
            "key": "o/r#7", "kind": "babysit", "outcome": "converged", "run_dir": dir,
            "ended_at": "2026-10-20T07:00:00Z"
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: history, atomically: true, encoding: .utf8)
        let status = try XCTUnwrap(Quorum.finished(at: history).first)
        XCTAssertEqual(status.headSHA, final)
        XCTAssertTrue(Landing.reviewCovers(status, head: final))
        XCTAssertFalse(Landing.reviewCovers(status, head: old), "the initial reviewed SHA is not the final accepted head")
    }

    func testADeadRunWithoutOutputIsNothing() throws {
        let dir = try folder()
        try #"{"repo":"o/r","number":7}"#.write(toFile: dir + "/target.json", atomically: true, encoding: .utf8)
        try "999999".write(toFile: dir + "/run.pid", atomically: true, encoding: .utf8)
        XCTAssertNil(Quorum.run(in: dir, kind: .review, modified: Date()))
    }

    func testABabysitThatDiedMidRunIsInterruptedNotItsFindings() throws {
        // As after muxy ended it: round 1, five critical found, no result.
        let dir = try folder()
        try """
        {"pid":1,"repo":"o/r","number":4399,"round":1,"max_iter":12,"phase":"tests","critical":5,"updated_at":"2026-10-19T21:52:02+02:00"}
        """.write(toFile: dir + "/progress.json", atomically: true, encoding: .utf8)
        try "999999".write(toFile: dir + "/run.pid", atomically: true, encoding: .utf8)
        let status = try XCTUnwrap(Quorum.run(in: dir, kind: .babysit, modified: Date()))
        XCTAssertFalse(status.running)
        XCTAssertTrue(status.interrupted)
        XCTAssertEqual(status.open, 0, "what it found so far doesn't count")
        XCTAssertFalse(status.succeeded)
        XCTAssertEqual(status.summary, L("quorum stopped: %@", L("interrupted")))
        XCTAssertEqual(Flow.quorumStep(status, installed: true, head: nil), .fix(L("Run quorum again")))
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
        let found = try XCTUnwrap(Radar.scan(root: repo.root, checkouts: [a, b], memo: Radar.Memo()))
        let forA = try XCTUnwrap(found[a])
        XCTAssertTrue(forA.contains { $0.other == b && $0.files == ["shared.txt"] })
        XCTAssertTrue(forA.contains { $0.withBase && $0.other == "origin/main" })
        XCTAssertTrue(found[b]?.contains { $0.other == a } == true)
    }

    /// A session that merged the base in carries the base's files: an older
    /// session's conflict with those is its conflict with the base, never a
    /// collision with the session that only kept up.
    func testTheBaseMergedInIsNotACollision() throws {
        let repo = try TempRepo()
        try repo.write("shared.txt", "one\ntwo\nthree\n")
        try repo.commit("Shared")
        try repo.addOrigin()
        let stale = try repo.addWorktree("stale", branch: "stale")
        let current = try repo.addWorktree("current", branch: "current")
        let idle = try repo.addWorktree("idle", branch: "idle")
        try repo.write("shared.txt", "one\nSTALE\nthree\n", in: stale)
        try repo.write("shared.txt", "one\nMAIN\nthree\n")
        try repo.commit("Main moves")
        try repo.git("push", "--quiet", "origin", "main")
        try repo.git("fetch", "--quiet", "origin")
        try repo.write("own.txt", "mine\n", in: current)
        try repo.commit("Own work", in: current)
        try repo.git("merge", "--quiet", "--no-edit", "origin/main", in: current)
        let found = try XCTUnwrap(Radar.scan(root: repo.root, checkouts: [stale, current, idle], memo: Radar.Memo()))
        XCTAssertEqual(found[stale], [Collision(other: "origin/main", withBase: true, files: ["shared.txt"])])
        XCTAssertNil(found[current])
        XCTAssertNil(found[idle], "a session with nothing of its own collides with nothing")
    }

    func testQuietWhenWorkDoesNotOverlap() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let a = try repo.addWorktree("a", branch: "a")
        let b = try repo.addWorktree("b", branch: "b")
        try repo.write("a.txt", "a\n", in: a)
        try repo.write("b.txt", "b\n", in: b)
        XCTAssertTrue(try XCTUnwrap(Radar.scan(root: repo.root, checkouts: [a, b], memo: Radar.Memo())).isEmpty)
    }

    func testIncompleteScanIsNotAnEmptyResult() throws {
        let repo = try TempRepo()
        let checkout = try repo.addWorktree("feature", branch: "feature")
        let missing = (repo.base as NSString).appendingPathComponent("missing-checkout")

        XCTAssertNil(Radar.scan(root: repo.root, checkouts: [checkout, missing], memo: Radar.Memo()))
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
        status.outcome = "failed"
        status.blockers = 1
        XCTAssertFalse(status.succeeded)
        XCTAssertEqual(status.open, 1)
    }

    func testAConvergedBabysitFixedWhatItFound() {
        // As in quorum's history: a babysit converged after fixing 2 blockers.
        var status = QuorumStatus(kind: .babysit, key: "o/r#1", running: false, blockers: 2, outcome: "converged", date: Date())
        XCTAssertEqual(status.open, 0)
        XCTAssertEqual(status.fixed, 2)
        XCTAssertTrue(status.succeeded)
        XCTAssertEqual(status.summary, L("quorum: clean, %d fixed", 2))
        // Still running, its counts are this round's: open.
        status.running = true
        XCTAssertEqual(status.open, 2)
        XCTAssertFalse(status.succeeded)
        // A review fixes nothing: what it found is open, whatever it ended with.
        let review = QuorumStatus(kind: .review, key: "o/r#1", running: false, critical: 1, outcome: "ok", date: Date())
        XCTAssertEqual(review.open, 1)
        XCTAssertFalse(review.succeeded)
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

final class QuorumConfigTests: XCTestCase {
    func testWritesKeysInPlaceKeepingComments() throws {
        let path = NSTemporaryDirectory() + "muxy-quorum-config-\(UUID())"
        try """
        # quorum configuration.
        REVIEWERS=6
        REVIEW_EFFORT="medium"\t# minimal, low, medium, high, xhigh
        POST=1

        """.write(toFile: path, atomically: true, encoding: .utf8)
        QuorumConfig.write("REVIEW_EFFORT", "high", at: path)
        QuorumConfig.write("REVIEWERS", "4", at: path)
        QuorumConfig.write("FIX_ENGINE", "claude", at: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("REVIEW_EFFORT=\"high\"\t# minimal, low, medium, high, xhigh"))
        XCTAssertTrue(text.contains("REVIEWERS=4\n"))
        XCTAssertTrue(text.contains("# quorum configuration."))
        let values = QuorumConfig.read(at: path)
        XCTAssertEqual(values["FIX_ENGINE"], "claude")
        XCTAssertEqual(values["POST"], "1")
        XCTAssertEqual(values["REVIEW_EFFORT"], "high")
    }
}

final class OwnPullTests: XCTestCase {
    func testFindsTheWorktreeThatHasTheBranch() throws {
        let repo = try TempRepo()
        // Made by hand beside the repository, like an agent's own worktree.
        let beside = (repo.base as NSString).appendingPathComponent("repo-3401")
        try repo.git("worktree", "add", "--quiet", "-b", "feat/3401-fix", beside, "HEAD")
        let inside = try repo.addWorktree("other", branch: "feat/other")
        XCTAssertEqual(HubModel.worktree(of: "feat/3401-fix", root: repo.root), beside)
        XCTAssertEqual(HubModel.worktree(of: "feat/other", root: repo.root), inside)
        XCTAssertEqual(HubModel.worktree(of: "main", root: repo.root), repo.root)
        // A prefix is not the branch.
        XCTAssertNil(HubModel.worktree(of: "feat/3401", root: repo.root))
        XCTAssertNil(HubModel.worktree(of: "nowhere", root: repo.root))
    }

    func testTestsKeepTheirStateToThemselves() {
        XCTAssertFalse(Paths.isApp)
        XCTAssertTrue(Paths.isTesting)
        XCTAssertNotEqual(StateDirectory.path, StateDirectory.installed)
        XCTAssertFalse(StateDirectory.path.hasPrefix(Paths.home + "/.local/state"))
        XCTAssertFalse(SavedSessions.file.path.contains("Application Support"))
    }
}

final class DirenvTests: XCTestCase {
    func testAWorktreeGetsTheMainCheckoutsAllowedEnvrcOnly() throws {
        guard let direnv = Shell.find("direnv") else { throw XCTSkip("direnv isn't installed") }
        let repo = try TempRepo()
        // direnv's allow list in a folder of the test's own, not yours.
        let data = (repo.base as NSString).appendingPathComponent("xdg")
        let previous = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        setenv("XDG_DATA_HOME", data, 1)
        defer { if let previous { setenv("XDG_DATA_HOME", previous, 1) } else { unsetenv("XDG_DATA_HOME") } }

        try repo.write(".envrc", "export MUXY_TEST=1\n")
        let same = try repo.addWorktree("same", branch: "same")
        try repo.write(".envrc", "export MUXY_TEST=1\n", in: same)
        let other = try repo.addWorktree("other", branch: "other")
        try repo.write(".envrc", "export MUXY_TEST=2\n", in: other)

        // Not allowed in the main checkout: nothing is allowed anywhere.
        Worktrees.allowDirenv(in: same, root: repo.root)
        XCTAssertFalse(Worktrees.isAllowed(direnv: direnv, in: same))

        _ = Shell.execute(direnv, ["allow", repo.root], in: repo.root)
        XCTAssertTrue(Worktrees.isAllowed(direnv: direnv, in: repo.root))
        Worktrees.allowDirenv(in: same, root: repo.root)
        Worktrees.allowDirenv(in: other, root: repo.root)
        XCTAssertTrue(Worktrees.isAllowed(direnv: direnv, in: same), "the same file, allowed in main")
        XCTAssertFalse(Worktrees.isAllowed(direnv: direnv, in: other), "a different file stays blocked")
    }
}

final class QuorumFlowTests: XCTestCase {
    func testBehaviorFollowsTheConfigWithQuorumsDefaults() {
        let defaults = QuorumBehavior([:])
        XCTAssertTrue(defaults.resolvesConflicts, "quorum's default is 1")
        XCTAssertFalse(defaults.babysitsDrafts)
        XCTAssertFalse(defaults.merges)
        XCTAssertTrue(defaults.posts)
        XCTAssertEqual(defaults.maxRounds, 12)

        // As in a real config: conflicts left alone, drafts allowed, the
        // retired AUTO_MERGE_BABYSIT key means nothing to quorum 1.16.
        let mine = QuorumBehavior(["RESOLVE_CONFLICTS": "0", "BABYSIT_DRAFTS": "1", "AUTO_MERGE_BABYSIT": "1", "MAX_ITER": "8"])
        XCTAssertFalse(mine.resolvesConflicts)
        XCTAssertTrue(mine.babysitsDrafts)
        XCTAssertFalse(mine.merges)
        XCTAssertEqual(mine.maxRounds, 8)

        XCTAssertTrue(QuorumBehavior(["AUTO_MERGE": "1"]).merges)
        XCTAssertFalse(QuorumBehavior(["AUTO_MERGE": "1", "POST": "0"]).merges, "quorum doesn't merge with POST=0")
    }

    func testDraftsGetTheGoAheadOnlyWhenTheConfigDoesntGiveIt() {
        XCTAssertEqual(Quorum.command(.babysit, pr: 7, draft: true, behavior: QuorumBehavior([:]), installed: QuorumCompat.tested), "quorum babysit --draft --divergence-scan 7")
        XCTAssertEqual(Quorum.command(.babysit, pr: 7, draft: true, behavior: QuorumBehavior(["BABYSIT_DRAFTS": "1"]), installed: QuorumCompat.tested), "quorum babysit --divergence-scan 7")
        XCTAssertEqual(Quorum.command(.babysit, pr: 7, draft: false, behavior: QuorumBehavior([:]), installed: QuorumCompat.tested), "quorum babysit --divergence-scan 7")
        XCTAssertEqual(Quorum.command(.babysit, pr: 7, draft: false, behavior: QuorumBehavior([:]), installed: "1.9.9"), "quorum babysit 7")
        XCTAssertEqual(Quorum.command(.review, pr: 7, draft: true, behavior: QuorumBehavior([:]), installed: QuorumCompat.tested), "quorum review 7")
    }

    func testStepsMatchWhatQuorumDoes() {
        let head = String(repeating: "a", count: 40)
        let newer = String(repeating: "b", count: 40)
        // Nothing yet: review and fix, one loop.
        XCTAssertEqual(Flow.quorumStep(nil, installed: true, head: head), .review)
        XCTAssertNil(Flow.quorumStep(nil, installed: false, head: head))
        // A review that only commented its 4 findings: babysit, not "fix 4".
        let commented = QuorumStatus(kind: .review, key: "o/r#1", running: false, critical: 4, outcome: "ok", date: Date())
        XCTAssertEqual(Flow.quorumStep(commented, installed: true, head: head), .review)
        // A babysit that stopped: again, with its reason on the card.
        var stopped = QuorumStatus(kind: .babysit, key: "o/r#1", running: false, outcome: "failed", date: Date())
        stopped.reason = "review did not converge after 12 review rounds"
        XCTAssertEqual(Flow.quorumStep(stopped, installed: true, head: head), .fix(L("Run quorum again")))
        XCTAssertEqual(stopped.summary, L("quorum stopped: %@", L("not clean after %d rounds", 12)))
        // Converged: nothing for quorum to do.
        var clean = QuorumStatus(kind: .babysit, key: "o/r#1", running: false, blockers: 2, outcome: "converged", date: Date())
        clean.headSHA = head
        XCTAssertNil(Flow.quorumStep(clean, installed: true, head: head))
        XCTAssertEqual(Flow.quorumStep(clean, installed: true, head: newer), .fix(L("Run quorum again")))
        XCTAssertEqual(clean.summary(for: newer), L("quorum: review outdated"))
        XCTAssertEqual(Flow.quorumStep(clean, installed: true, head: nil), .fix(L("Run quorum again")))
        // Running: shown in the review column with its round and phase.
        var running = QuorumStatus(kind: .babysit, key: "o/r#1", running: true, phase: "fix", round: 2, date: Date())
        running.maxRounds = 12
        XCTAssertEqual(running.summary, "quorum: " + L("round %d of %d", 2, 12) + " · " + L("fixes"))
        XCTAssertEqual(Flow.quorumStep(running, installed: true, head: newer)?.stage, .review)
    }
}

final class QuorumFixesTests: XCTestCase {
    func testSeesAndTakesInWhatQuorumPushed() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let checkout = try repo.addWorktree("feature", branch: "feature")
        try repo.write("a.txt", "agent\n", in: checkout)
        try repo.commit("Agent's work", in: checkout)
        try repo.git("push", "--quiet", "-u", "origin", "feature", in: checkout)

        // quorum works in a clone of its own and pushes a fix to the branch.
        let quorum = (repo.base as NSString).appendingPathComponent("quorum")
        try TempRepo.run(["clone", "--quiet", "--branch", "feature", try XCTUnwrap(repo.origin), quorum], in: repo.base)
        try repo.write("a.txt", "agent, fixed\n", in: quorum)
        try repo.git("-c", "user.name=q", "-c", "user.email=q@q", "commit", "--quiet", "-am", "quorum's fix", in: quorum)
        try repo.git("push", "--quiet", "origin", "feature", in: quorum)

        let state = Landing.inspect(checkout: checkout, root: repo.root)
        XCTAssertFalse(state.dirty)
        XCTAssertEqual(state.fromOrigin, 1, "the fix on origin is seen")

        Landing.takeFixes(in: checkout)
        let expectation = expectation(description: "fast-forwarded")
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(repo.read("a.txt", in: checkout), "agent, fixed\n")
        XCTAssertEqual(Landing.inspect(checkout: checkout, root: repo.root).fromOrigin, 0)
    }

    func testLandingDoesNotUseABaseThatCouldNotBeFetched() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let checkout = try repo.addWorktree("feature", branch: "feature")
        try repo.git("remote", "set-url", "origin", "/definitely/not/a/repository", in: repo.root)

        XCTAssertFalse(Landing.inspect(checkout: checkout, root: repo.root).baseAvailable)
    }
}

final class QuorumLaunchTests: XCTestCase {
    func testRunsOnItsOwnIntoALog() throws {
        let repo = try TempRepo()
        // Any command: it runs in the login shell, in the folder, output in the log.
        let log = try XCTUnwrap(Quorum.launch("pwd; echo from-quorum", in: repo.root, name: "test-1"))
        defer { try? FileManager.default.removeItem(atPath: log) }
        XCTAssertTrue(log.hasPrefix(Quorum.logs))
        XCTAssertFalse(log.hasPrefix(Paths.home + "/.local/state/muxy/"), "tests keep to their own state")
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            if text.contains("from-quorum") { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(text.contains("from-quorum"))
        XCTAssertTrue(text.contains(repo.root))
    }
}

final class QuorumPrepareTests: XCTestCase {
    private func setUp(_ repo: TempRepo) throws -> (checkout: String, other: String) {
        try repo.addOrigin()
        let checkout = try repo.addWorktree("feature", branch: "feature")
        try repo.write("a.txt", "one\n", in: checkout)
        try repo.commit("One", in: checkout)
        try repo.git("push", "--quiet", "origin", "feature", in: checkout)
        // Someone else's clone, to move origin on.
        let other = (repo.base as NSString).appendingPathComponent("other")
        try TempRepo.run(["clone", "--quiet", "--branch", "feature", try XCTUnwrap(repo.origin), other], in: repo.base)
        return (checkout, other)
    }

    private func originHead(_ repo: TempRepo) throws -> String {
        try repo.git("ls-remote", "origin", "refs/heads/feature").split(separator: "\t").first.map(String.init) ?? ""
    }

    func testUnpushedCommitsArePushedFirst() throws {
        let repo = try TempRepo()
        let (checkout, _) = try setUp(repo)
        // A pre-push hook like Phoenix's: only the checked-out branch, from
        // its own checkout, may be pushed.
        let hook = repo.path(".git/hooks/pre-push")
        try """
        #!/bin/sh
        head=$(git rev-parse HEAD)
        while read local_ref local_oid remote_ref remote_oid; do
          [ "$local_oid" = "$head" ] || { echo 'Push one checked-out branch at a time' >&2; exit 1; }
        done
        """.write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        // Like the merge of the base muxy made before the session closed.
        try repo.write("b.txt", "two\n", in: checkout)
        try repo.commit("Two", in: checkout)
        XCTAssertNil(Quorum.prepare(branch: "feature", root: repo.root))
        XCTAssertEqual(try originHead(repo), try repo.head(in: checkout))
    }

    func testUnacceptedHeadIsNeverPushedDuringPreparation() throws {
        let repo = try TempRepo()
        let (checkout, _) = try setUp(repo)
        let accepted = try repo.head(in: checkout)
        try repo.write("b.txt", "unaccepted\n", in: checkout)
        try repo.commit("Unaccepted", in: checkout)

        XCTAssertNotNil(Quorum.prepare(branch: "feature", root: repo.root, accepted: accepted))
        XCTAssertEqual(try originHead(repo), accepted)
    }

    func testABranchBehindOriginIsMovedUp() throws {
        let repo = try TempRepo()
        let (checkout, other) = try setUp(repo)
        try repo.write("c.txt", "theirs\n", in: other)
        try repo.git("add", "-A", in: other)
        try repo.git("-c", "user.name=o", "-c", "user.email=o@o", "commit", "--quiet", "-m", "Theirs", in: other)
        try repo.git("push", "--quiet", "origin", "feature", in: other)
        XCTAssertNil(Quorum.prepare(branch: "feature", root: repo.root))
        XCTAssertEqual(repo.read("c.txt", in: checkout), "theirs\n")
    }

    func testBothWaysOrUncommittedIsYours() throws {
        let repo = try TempRepo()
        let (checkout, other) = try setUp(repo)
        try repo.write("c.txt", "theirs\n", in: other)
        try repo.git("add", "-A", in: other)
        try repo.git("-c", "user.name=o", "-c", "user.email=o@o", "commit", "--quiet", "-m", "Theirs", in: other)
        try repo.git("push", "--quiet", "origin", "feature", in: other)
        try repo.write("d.txt", "mine\n", in: checkout)
        XCTAssertNotNil(Quorum.prepare(branch: "feature", root: repo.root), "uncommitted")
        try repo.commit("Mine", in: checkout)
        let before = try originHead(repo)
        XCTAssertNotNil(Quorum.prepare(branch: "feature", root: repo.root), "both moved")
        XCTAssertEqual(try originHead(repo), before, "nothing was pushed over theirs")
    }
}
