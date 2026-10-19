import XCTest
@testable import muxy

final class WorktreeRecipeTests: XCTestCase {
    func testLoadReadsEveryKey() throws {
        let repo = try TempRepo()
        try repo.write(".wtconfig", """
        [wt]
            base = development
            env = .env
            copy = frontend/.env.local
            copy = secrets
            port = SERVER_HOST_PORT
            port = "PORT:3000"
            port = "WEB_PORT:abc"
            port = "not a name"
            compose = yes
            bootstrap = "devbox run bootstrap"
            teardown = docker compose down
            disposable = node_modules
            disposable = dist/
        """)
        let recipe = try XCTUnwrap(WorktreeRecipe.load(root: repo.root))
        XCTAssertEqual(recipe.base, "development")
        XCTAssertEqual(recipe.env, ".env")
        XCTAssertEqual(recipe.copies, ["frontend/.env.local", "secrets"])
        XCTAssertEqual(recipe.ports.map(\.name), ["SERVER_HOST_PORT", "PORT", "WEB_PORT"])
        XCTAssertEqual(recipe.ports.map(\.start), [nil, 3000, nil])
        XCTAssertTrue(recipe.compose)
        XCTAssertEqual(recipe.bootstrap, "devbox run bootstrap")
        XCTAssertEqual(recipe.teardown, "docker compose down")
        XCTAssertEqual(recipe.disposable, ["node_modules", "dist/"])
    }

    func testLoadWithoutFileIsNil() throws {
        let repo = try TempRepo()
        XCTAssertNil(WorktreeRecipe.load(root: repo.root))
    }

    func testComposeOffAndEmptySection() throws {
        let repo = try TempRepo()
        try repo.write(".wtconfig", "[wt]\n    compose = false\n")
        let recipe = try XCTUnwrap(WorktreeRecipe.load(root: repo.root))
        XCTAssertFalse(recipe.compose)
        XCTAssertNil(recipe.env)
        XCTAssertTrue(recipe.ports.isEmpty)
    }

    func testBrokenFileIsNil() throws {
        let repo = try TempRepo()
        try repo.write(".wtconfig", "[wt\n base = x\n")
        XCTAssertNil(WorktreeRecipe.load(root: repo.root))
    }
}

final class WorktreeSetUpTests: XCTestCase {
    private func repoWithEnv(_ env: String, recipe: String) throws -> TempRepo {
        let repo = try TempRepo()
        try repo.write(".gitignore", ".env\n.env.local\nlocal/\n")
        try repo.commit("Ignore env files")
        try repo.write(".env", env)
        try repo.write(".wtconfig", recipe)
        return repo
    }

    func testCopiesFilesButKeepsTrackedOnes() throws {
        let repo = try repoWithEnv("A=1\n", recipe: """
        [wt]
            env = .env
            copy = local
            copy = README.md
            copy = ../outside
            copy = missing.txt
        """)
        try repo.write("local/nested/key.txt", "secret\n")
        try repo.write("README.md", "changed in main, uncommitted\n")
        try repo.write("../outside", "nope\n")
        let worktree = try repo.addWorktree("one", branch: "one")
        let recipe = try XCTUnwrap(WorktreeRecipe.load(root: repo.root))
        try Worktrees.setUp(worktree, root: repo.root, recipe: recipe) { _ in }

        XCTAssertEqual(repo.read(".env", in: worktree), "A=1\n")
        XCTAssertEqual(repo.read("local/nested/key.txt", in: worktree), "secret\n")
        XCTAssertEqual(repo.read("README.md", in: worktree), "hello\n", "tracked files win")
        XCTAssertFalse(repo.exists(repo.path(".worktrees/outside")), "nothing is copied outside the worktree")
        XCTAssertFalse(repo.exists((worktree as NSString).appendingPathComponent("missing.txt")))
    }

    func testLeasesPortsSkippingOtherCheckoutsAndBoundPorts() throws {
        let start = freePortRange(8)
        let repo = try repoWithEnv("""
        SERVER_HOST_PORT=\(start)
        DATABASE_URL=postgres://u:p@localhost:\(start)/db
        API=http://127.0.0.1:\(start)/v1
        OTHER=http://example.com:\(start)/ and localhost:\(start)0
        """ + "\n", recipe: """
        [wt]
            env = .env
            port = SERVER_HOST_PORT
        """)
        // Another worktree already holds start+1 in its env file.
        let other = try repo.addWorktree("other", branch: "other")
        try repo.write(".env", "SERVER_HOST_PORT=\(start + 1)\n", in: other)
        // Something listens on start+2 right now.
        let listener = try XCTUnwrap(Listener(port: start + 2))
        defer { listener.close() }

        let worktree = try repo.addWorktree("mine", branch: "mine")
        let recipe = try XCTUnwrap(WorktreeRecipe.load(root: repo.root))
        try Worktrees.setUp(worktree, root: repo.root, recipe: recipe) { _ in }

        let env = Worktrees.read((worktree as NSString).appendingPathComponent(".env"))
        XCTAssertEqual(env["SERVER_HOST_PORT"], "\(start + 3)")
        XCTAssertEqual(env["DATABASE_URL"], "postgres://u:p@localhost:\(start + 3)/db")
        XCTAssertEqual(env["API"], "http://127.0.0.1:\(start + 3)/v1")
        XCTAssertEqual(env["OTHER"], "http://example.com:\(start)/ and localhost:\(start)0",
                       "only localhost URLs with exactly that port move")
        XCTAssertEqual(repo.read(".env").map { $0.contains("SERVER_HOST_PORT=\(start)\n") }, true,
                       "the main checkout keeps its port")
    }

    func testSkipsPortsBoundOnIPv6() throws {
        let start = freePortRange(4)
        let repo = try repoWithEnv("SERVER_HOST_PORT=\(start)\n", recipe: """
        [wt]
            env = .env
            port = SERVER_HOST_PORT
        """)
        let listener = try XCTUnwrap(Listener(ipv6Port: start + 1))
        defer { listener.close() }
        let worktree = try repo.addWorktree("mine", branch: "mine")
        try Worktrees.setUp(worktree, root: repo.root, recipe: XCTUnwrap(WorktreeRecipe.load(root: repo.root))) { _ in }
        let env = Worktrees.read((worktree as NSString).appendingPathComponent(".env"))
        XCTAssertEqual(env["SERVER_HOST_PORT"], "\(start + 2)", "a dev server on [::] holds the port too")
    }

    func testPortsWithStartGoToPortsFile() throws {
        let start = freePortRange(4)
        let repo = try repoWithEnv("A=1\n", recipe: """
        [wt]
            env = .env
            port = "PORT:\(start)"
        """)
        let other = try repo.addWorktree("other", branch: "other")
        try repo.write(WorktreeRecipe.portsFile, "PORT=\(start + 1)\n", in: other)
        let worktree = try repo.addWorktree("mine", branch: "mine")
        try Worktrees.setUp(worktree, root: repo.root, recipe: XCTUnwrap(WorktreeRecipe.load(root: repo.root))) { _ in }

        let ports = Worktrees.read((worktree as NSString).appendingPathComponent(WorktreeRecipe.portsFile))
        XCTAssertEqual(ports["PORT"], "\(start + 2)")
        XCTAssertNil(Worktrees.read((worktree as NSString).appendingPathComponent(".env"))["PORT"])
    }

    func testComposeProjectName() throws {
        let repo = try repoWithEnv("A=1\n", recipe: """
        [wt]
            env = .env
            compose = true
        """)
        let worktree = try repo.addWorktree("Fix.Login", branch: "fix")
        try Worktrees.setUp(worktree, root: repo.root, recipe: XCTUnwrap(WorktreeRecipe.load(root: repo.root))) { _ in }
        let env = Worktrees.read((worktree as NSString).appendingPathComponent(".env"))
        XCTAssertEqual(env["COMPOSE_PROJECT_NAME"], "repo-fix-login")
        XCTAssertEqual(env["A"], "1")
    }

    func testBootstrapRunsInWorktree() throws {
        let repo = try repoWithEnv("A=1\n", recipe: """
        [wt]
            bootstrap = "touch bootstrapped"
        """)
        let worktree = try repo.addWorktree("one", branch: "one")
        var steps: [String] = []
        try Worktrees.setUp(worktree, root: repo.root, recipe: XCTUnwrap(WorktreeRecipe.load(root: repo.root))) {
            steps.append($0)
        }
        XCTAssertTrue(repo.exists((worktree as NSString).appendingPathComponent("bootstrapped")))
        XCTAssertFalse(repo.exists(repo.path("bootstrapped")))
        XCTAssertEqual(steps.count, 1)
    }

    func testBootstrapFailureSurfacesLastLines() throws {
        let repo = try repoWithEnv("A=1\n", recipe: """
        [wt]
            bootstrap = "sh -c 'for n in 1 2 3 4 5; do echo line$n >&2; done; exit 3'"
        """)
        let worktree = try repo.addWorktree("one", branch: "one")
        let recipe = try XCTUnwrap(WorktreeRecipe.load(root: repo.root))
        XCTAssertThrowsError(try Worktrees.setUp(worktree, root: repo.root, recipe: recipe) { _ in }) { error in
            let message = (error as? Launcher.Failure)?.message ?? ""
            XCTAssertTrue(message.hasSuffix("line3\nline4\nline5"), message)
            XCTAssertFalse(message.contains("line2"), message)
        }
    }
}

final class WorktreeFinishedTests: XCTestCase {
    private func setUp(recipe: String? = nil) throws -> (TempRepo, String) {
        let repo = try TempRepo()
        try repo.write(".gitignore", ".env\n")
        try repo.commit("Ignore env")
        if let recipe { try repo.write(".wtconfig", recipe) }
        return (repo, try repo.addWorktree("work", branch: "work"))
    }

    func testCleanWorktreeIsFinished() throws {
        let (repo, worktree) = try setUp()
        try repo.write(".env", "IGNORED=1\n", in: worktree)
        XCTAssertTrue(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
    }

    func testModifiedFileIsNotFinished() throws {
        let (repo, worktree) = try setUp()
        try repo.write("README.md", "edited\n", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
    }

    func testStagedFileIsNotFinished() throws {
        let (repo, worktree) = try setUp()
        try repo.write("new.txt", "x\n", in: worktree)
        try repo.git("add", "new.txt", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
    }

    func testUntrackedFileIsNotFinished() throws {
        let (repo, worktree) = try setUp()
        try repo.write("notes/idea.md", "x\n", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
    }

    func testUntrackedDisposableIsFinished() throws {
        let (repo, worktree) = try setUp(recipe: """
        [wt]
            disposable = node_modules
            disposable = "build output/"
        """)
        try repo.write("node_modules/pkg/index.js", "x\n", in: worktree)
        try repo.write("build output/app.js", "x\n", in: worktree)
        XCTAssertTrue(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
        // Not a prefix match on names: node_modules2 is work.
        try repo.write("node_modules2/a", "x\n", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
    }

    /// A tracked file changed in a disposable folder is still a change,
    /// wherever it lands in git's output.
    func testModifiedTrackedFileInDisposableIsNotFinished() throws {
        let repo = try TempRepo()
        try repo.write("dist/app.js", "v1\n")
        try repo.write("zzz.txt", "v1\n")
        try repo.commit("Tracked build output")
        try repo.write(".wtconfig", "[wt]\n    disposable = dist\n")
        let worktree = try repo.addWorktree("work", branch: "work")
        try repo.write("dist/app.js", "v2\n", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
        try repo.write("zzz.txt", "v2\n", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
    }

    func testPortsFileAloneIsFinished() throws {
        let (repo, worktree) = try setUp(recipe: "[wt]\n    env = .env\n    port = \"PORT:3000\"\n")
        try repo.write(".env", "A=1\n")
        try Worktrees.setUp(worktree, root: repo.root, recipe: XCTUnwrap(WorktreeRecipe.load(root: repo.root))) { _ in }
        XCTAssertTrue(repo.exists((worktree as NSString).appendingPathComponent(WorktreeRecipe.portsFile)))
        XCTAssertTrue(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root),
                      "muxy's own ports file is not work")
        XCTAssertEqual(try repo.git("status", "--porcelain", in: worktree), "", "nor can an agent commit it")
    }

    func testNewCommitIsNotFinished() throws {
        let (repo, worktree) = try setUp()
        try repo.write("feature.txt", "x\n", in: worktree)
        try repo.commit("Feature", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: nil, root: repo.root))
    }

    func testCommitsMatchingMergedPullRequestAreFinished() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let worktree = try repo.addWorktree("work", branch: "work")
        try repo.write("feature.txt", "x\n", in: worktree)
        try repo.commit("Feature", in: worktree)
        // GitHub keeps the PR's head at refs/pull/<n>/head.
        try repo.git("push", "--quiet", "origin", "HEAD:refs/pull/7/head", in: worktree)
        XCTAssertTrue(Worktrees.isFinished(worktree, pullRequest: 7, root: repo.root))

        // A commit after what was merged is work that would be lost.
        try repo.commit("After merge", in: worktree)
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: 7, root: repo.root))
    }

    func testUnknownPullRequestIsNotFinished() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let worktree = try repo.addWorktree("work", branch: "work")
        XCTAssertFalse(Worktrees.isFinished(worktree, pullRequest: 99, root: repo.root))
    }

    func testIsManaged() throws {
        XCTAssertTrue(Worktrees.isManaged("/r/.worktrees/a", root: "/r"))
        XCTAssertFalse(Worktrees.isManaged("/r", root: "/r"))
        XCTAssertFalse(Worktrees.isManaged("/r/.worktrees", root: "/r"))
        XCTAssertFalse(Worktrees.isManaged("/r/.worktreesX/a", root: "/r"))
        XCTAssertFalse(Worktrees.isManaged("/other/.worktrees/a", root: "/r"))
    }
}

final class WorktreeRemoveTests: XCTestCase {
    func testRemovesWorktreeAndBranchAfterTeardown() throws {
        let repo = try TempRepo()
        let marker = (repo.base as NSString).appendingPathComponent("torn-down")
        try repo.write(".wtconfig", "[wt]\n    teardown = \"pwd > '\(marker)'\"\n")
        let worktree = try repo.addWorktree("work", branch: "work")
        try repo.write("draft.txt", "x\n", in: worktree)

        Worktrees.remove(worktree, branch: "work", root: repo.root)

        XCTAssertEqual(repo.read("torn-down", in: repo.base)?.trimmingCharacters(in: .whitespacesAndNewlines), worktree)
        XCTAssertFalse(repo.exists(worktree))
        XCTAssertFalse(try repo.git("branch", "--list", "work").contains("work"))
        XCTAssertEqual(try repo.git("branch", "--show-current"), "main")
        XCTAssertEqual(Worktrees.checkouts(of: repo.root), [repo.root])
    }

    func testNeverTouchesTheMainCheckout() throws {
        let repo = try TempRepo()
        let marker = (repo.base as NSString).appendingPathComponent("torn-down")
        try repo.write(".wtconfig", "[wt]\n    teardown = \"touch '\(marker)'\"\n")
        try repo.write("uncommitted.txt", "x\n")
        let head = try repo.head()

        Worktrees.remove(repo.root, branch: "main", root: repo.root)

        XCTAssertFalse(repo.exists(marker), "teardown must not run in the main checkout")
        XCTAssertTrue(repo.exists(repo.path("uncommitted.txt")))
        XCTAssertEqual(try repo.head(), head)
        XCTAssertEqual(try repo.git("branch", "--show-current"), "main")
    }

    func testLeavesUnmanagedWorktreeAlone() throws {
        let repo = try TempRepo()
        let outside = (repo.base as NSString).appendingPathComponent("beside")
        try repo.git("worktree", "add", "--quiet", "-b", "beside", outside)
        Worktrees.remove(outside, branch: "beside", root: repo.root)
        XCTAssertTrue(repo.exists(outside))
        XCTAssertTrue(try repo.git("branch", "--list", "beside").contains("beside"))
    }
}
