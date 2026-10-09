import XCTest
@testable import muxy

final class SparesTests: XCTestCase {
    private func marker(_ repo: TempRepo) -> String {
        repo.path(".git/muxy-spare")
    }

    private func isDetached(_ path: String) -> Bool {
        Shell.execute("/usr/bin/git", ["symbolic-ref", "--quiet", "HEAD"], in: path).status != 0
    }

    func testPrepareThenTakeHandsOverADetachedSpareOnce() async throws {
        let repo = try TempRepo()
        let spares = Spares()
        spares.prepare(root: repo.root)
        let taken = await spares.take(root: repo.root)
        let path = try XCTUnwrap(taken)
        XCTAssertTrue(Worktrees.isManaged(path, root: repo.root))
        XCTAssertTrue(isDetached(path))
        XCTAssertEqual(try repo.head(in: path), try repo.head())
        XCTAssertFalse(repo.exists(marker(repo)))
        let again = await spares.take(root: repo.root)
        XCTAssertNil(again, "a spare is handed out once")
    }

    func testReadySpareIsRememberedAcrossInstances() async throws {
        let repo = try TempRepo()
        let first = Spares()
        first.prepare(root: repo.root)
        // Waits for the spare and gives it back, ready, as a quit muxy left it.
        let taken = await first.take(root: repo.root)
        let path = try XCTUnwrap(taken)
        try path.write(toFile: marker(repo), atomically: true, encoding: .utf8)

        let second = Spares()
        second.prepare(root: repo.root)
        XCTAssertEqual(try String(contentsOfFile: marker(repo), encoding: .utf8), path, "a ready spare is kept")
        let handed = await second.take(root: repo.root)
        XCTAssertEqual(handed, path)
    }

    func testHalfMadeSpareOfDeadMuxyIsCleanedUp() async throws {
        let repo = try TempRepo()
        let stale = try repo.addWorktree("session-stale", detach: true)
        let dead = deadPid()
        try "making \(dead) \(stale)".write(toFile: marker(repo), atomically: true, encoding: .utf8)

        let spares = Spares()
        spares.prepare(root: repo.root)
        let taken = await spares.take(root: repo.root)
        XCTAssertFalse(repo.exists(stale))
        XCTAssertFalse(Worktrees.checkouts(of: repo.root).contains(stale))
        let fresh = try XCTUnwrap(taken, "a new spare replaces it")
        XCTAssertNotEqual(fresh, stale)
    }

    func testSpareAnotherLiveMuxyMakesIsLeftAlone() async throws {
        let repo = try TempRepo()
        let other = try repo.addWorktree("session-other", detach: true)
        let text = "making \(getpid()) \(other)"
        try text.write(toFile: marker(repo), atomically: true, encoding: .utf8)

        let spares = Spares()
        spares.prepare(root: repo.root)
        let taken = await spares.take(root: repo.root)
        XCTAssertNil(taken)
        XCTAssertTrue(repo.exists(other))
        XCTAssertEqual(try String(contentsOfFile: marker(repo), encoding: .utf8), text)
        XCTAssertEqual(Worktrees.checkouts(of: repo.root).count, 2, "no second spare is made")
    }

    func testSpareThatGotABranchIsNotTaken() async throws {
        let repo = try TempRepo()
        let path = try repo.addWorktree("session-x", detach: true)
        try path.write(toFile: marker(repo), atomically: true, encoding: .utf8)
        try repo.git("switch", "--quiet", "-c", "someone-elses", in: path)

        let taken = await Spares().take(root: repo.root)
        XCTAssertNil(taken)
        XCTAssertTrue(repo.exists(path), "someone works there")
    }

    func testSpareWhoseFolderIsGoneIsNotTaken() async throws {
        let repo = try TempRepo()
        try repo.path(".worktrees/gone").write(toFile: marker(repo), atomically: true, encoding: .utf8)
        let taken = await Spares().take(root: repo.root)
        XCTAssertNil(taken)
    }

    /// A pid nobody uses: a child that already exited and was reaped.
    private func deadPid() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}

final class LauncherTests: XCTestCase {
    func testStartPointPrefersBaseOnOrigin() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        try repo.git("branch", "development")
        var recipe = WorktreeRecipe()
        recipe.base = "development"
        XCTAssertEqual(Launcher.startPoint(in: repo.root, recipe: recipe), "development", "local only")
        try repo.git("push", "--quiet", "origin", "development")
        XCTAssertEqual(Launcher.startPoint(in: repo.root, recipe: recipe), "origin/development")
        recipe.base = "missing"
        XCTAssertEqual(Launcher.startPoint(in: repo.root, recipe: recipe), "origin/main")
        XCTAssertEqual(Launcher.startPoint(in: repo.root, recipe: nil), "origin/main")
    }

    /// Never "HEAD": worktrees read it as their own commit.
    func testStartPointWithoutOriginHeadIsTheMainCheckoutsBranch() throws {
        let repo = try TempRepo()
        XCTAssertEqual(Launcher.startPoint(in: repo.root, recipe: nil), "main")
        try repo.addOrigin()
        try repo.git("remote", "set-head", "origin", "--delete")
        XCTAssertEqual(Launcher.startPoint(in: repo.root, recipe: nil), "main")
        let head = try repo.head()
        try repo.git("switch", "--quiet", "--detach")
        XCTAssertEqual(Launcher.startPoint(in: repo.root, recipe: nil), head)
    }

    func testMainCheckoutOfWorktree() throws {
        let repo = try TempRepo()
        let worktree = try repo.addWorktree("work", branch: "work")
        XCTAssertEqual(Launcher.mainCheckout(of: worktree), repo.root)
        XCTAssertEqual(Launcher.mainCheckout(of: repo.root), repo.root)
        XCTAssertNil(Launcher.mainCheckout(of: repo.base))
    }

    func testFreeFolderCountsUp() throws {
        let repo = try TempRepo()
        let first = Launcher.freeFolder(in: repo.root, named: "fix")
        XCTAssertEqual(first, repo.path(".worktrees/fix"))
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        XCTAssertEqual(Launcher.freeFolder(in: repo.root, named: "fix"), repo.path(".worktrees/fix-2"))
    }

    /// The main checkout moved on since the spare was made: the session
    /// starts from where it is now, not where it was.
    func testStaleSpareIsBroughtUpToDate() async throws {
        for withOrigin in [false, true] {
            let repo = try TempRepo()
            if withOrigin { try repo.addOrigin() }
            let spare = try repo.addWorktree("session-old", detach: true)
            try spare.write(toFile: repo.path(".git/muxy-spare"), atomically: true, encoding: .utf8)
            try repo.commit("Moved on")
            if withOrigin { try repo.git("push", "--quiet", "origin", "main") }
            let now = try repo.head()

            let made = try await Launcher.makeWorktree(from: repo.root, branch: "feat/x") { _ in }
            XCTAssertEqual(made.path, spare, "the spare is used")
            XCTAssertNil(made.problem)
            XCTAssertEqual(try repo.head(in: made.path), now, withOrigin ? "with origin" : "without origin")
            XCTAssertEqual(try repo.git("branch", "--show-current", in: made.path), "feat/x")
            // makeWorktree readies the next spare: let it finish before cleanup.
            _ = await Spares.shared.take(root: repo.root)
        }
    }

    func testExistingBranchIsCheckedOutAsIs() async throws {
        let repo = try TempRepo()
        try repo.git("branch", "old")
        try repo.commit("Main moved")
        let made = try await Launcher.makeWorktree(from: repo.root, branch: "old") { _ in }
        XCTAssertEqual(made.path, repo.path(".worktrees/old"))
        XCTAssertEqual(try repo.git("branch", "--show-current", in: made.path), "old")
        XCTAssertNotEqual(try repo.head(in: made.path), try repo.head())
        XCTAssertTrue(repo.read(".git/info/exclude")?.contains("/.worktrees/") == true)
        _ = await Spares.shared.take(root: repo.root)
    }
}
