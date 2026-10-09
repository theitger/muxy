import Foundation

/// What "New Session" asks for: where, which agent, what it should do, and
/// whether the work gets its own worktree and branch.
struct SessionSpec {
    var directory: String
    var agent: AgentKind?
    var prompt = ""
    /// Branch for a new worktree; nil works in `directory` itself.
    var branch: String?
    /// `branch` is a placeholder: renamed after the task once it runs.
    var autoName = false
}

enum Launcher {
    struct Failure: Error {
        let message: String
    }

    /// The main checkout of the repository `directory` is in — worktrees
    /// share its git dir. nil outside git.
    static func mainCheckout(of directory: String) -> String? {
        guard let common = Shell.run(
            "/usr/bin/git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory
        ) else { return nil }
        let url = URL(fileURLWithPath: common)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : nil
    }

    /// `line` run by your login shell (so PATH and friends are yours),
    /// which then stays as the tab's shell once the agent exits.
    static func shellCommand(running line: String) -> String {
        let shell = Paths.userShell
        return "\(shell) -l -c \(quoted("\(line); exec \(shell) -l"))"
    }

    /// Single-quoted for /bin/sh, which Ghostty runs the command with.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where worktrees live: inside the main checkout, so agents that trust
    /// the repository trust them too (Claude Code asks again for a folder
    /// beside it). Kept out of git by `.git/info/exclude`.
    static let worktreesFolder = ".worktrees"

    /// A ready worktree on `branch`: the repository's spare when one is
    /// waiting (see Spares), else a new one, set up after `.wtconfig`. An
    /// existing branch is checked out as is. `problem`: set up, but its
    /// bootstrap failed. Blocking; call off the main thread.
    static func makeWorktree(
        from directory: String, branch: String, progress: @escaping @Sendable (String) -> Void
    ) async throws -> (path: String, problem: String?) {
        guard let root = mainCheckout(of: directory) else {
            throw Failure(message: L("Not a git repository."))
        }
        excludeWorktrees(in: root)
        let recipe = WorktreeRecipe.load(root: root)
        let git = "/usr/bin/git"
        let exists = Shell.execute(git, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root).status == 0
        defer { Spares.shared.prepare(root: root) }

        if !exists, let path = await Spares.shared.take(root: root) {
            var problem: String?
            let start = startPoint(in: root, recipe: recipe)
            // Made a while ago: brought up to date, its setup redone.
            if Shell.run(git, ["rev-parse", "HEAD"], in: path) != Shell.run(git, ["rev-parse", start], in: root) {
                _ = Shell.execute(git, ["reset", "--hard", "--quiet", start], in: path)
                if let recipe, recipe.bootstrap != nil {
                    var again = recipe
                    again.copies = []
                    again.env = nil
                    problem = (try? Worktrees.setUp(path, root: root, recipe: again, progress: progress)) == nil
                        ? L("Setup failed, the session runs without it.") : nil
                }
            }
            if Shell.execute(git, ["switch", "--quiet", "-c", branch], in: path).status == 0 {
                return (path, problem)
            }
        }

        let path = freeFolder(in: root, named: branch.replacingOccurrences(of: "/", with: "-"))
        let result: Shell.Result
        if exists {
            result = Shell.execute(git, ["worktree", "add", path, branch], in: root)
        } else {
            // --no-track: the new branch is its own, not a follower of main
            // (and it counts as unpushed until the agent pushes it).
            result = Shell.execute(
                git, ["worktree", "add", "--no-track", "-b", branch, path, startPoint(in: root, recipe: recipe)], in: root
            )
        }
        guard result.status == 0 else {
            throw Failure(message: result.error.isEmpty ? L("git worktree add failed.") : result.error)
        }
        guard let recipe else { return (path, nil) }
        do {
            try Worktrees.setUp(path, root: root, recipe: recipe, progress: progress)
            return (path, nil)
        } catch {
            return (path, (error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    /// `<repo>/.worktrees/<name>`, or `<name>-2`, … when taken.
    static func freeFolder(in root: String, named name: String) -> String {
        let parent = (root as NSString).appendingPathComponent(worktreesFolder)
        var path = (parent as NSString).appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: path) {
            path = (parent as NSString).appendingPathComponent("\(name)-\(suffix)")
            suffix += 1
        }
        return path
    }

    /// Adds `/.worktrees/` to the repository's local ignore list, once.
    private static func excludeWorktrees(in root: String) {
        let exclude = (root as NSString).appendingPathComponent(".git/info/exclude")
        let line = "/\(worktreesFolder)/"
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(Substring(line)) else { return }
        try? FileManager.default.createDirectory(
            atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let prefix = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try? (current + prefix + line + "\n").write(toFile: exclude, atomically: true, encoding: .utf8)
    }

    /// Where new branches start: the recipe's base (as origin has it, when
    /// it does), else origin's default branch, as last fetched: starting
    /// never waits on the network (`prefetch` runs while ⌘N is open).
    static func startPoint(in root: String, recipe: WorktreeRecipe?) -> String {
        let git = "/usr/bin/git"
        if let base = recipe?.base {
            for candidate in ["origin/\(base)", base]
                where Shell.execute(git, ["rev-parse", "--verify", "--quiet", candidate], in: root).status == 0 {
                return candidate
            }
        }
        guard let remote = Shell.run(git, ["rev-parse", "--abbrev-ref", "origin/HEAD"], in: root),
              remote.hasPrefix("origin/")
        else { return "HEAD" }
        return remote
    }

    /// Fetches the branch new worktrees start from in the background, so a
    /// worktree started a moment later begins from what is merged now; then
    /// readies the repository's spare worktree.
    static func prefetch(_ directory: String, spare: Bool) {
        Task.detached(priority: .utility) {
            guard let root = mainCheckout(of: directory) else { return }
            let start = startPoint(in: root, recipe: WorktreeRecipe.load(root: root))
            if start.hasPrefix("origin/") {
                _ = Shell.execute("/usr/bin/git", ["fetch", "--quiet", "origin", String(start.dropFirst("origin/".count))],
                                  in: root, timeout: 20)
            }
            if spare { Spares.shared.prepare(root: root) }
        }
    }
}

extension Shell {
    struct Result {
        var status: Int32
        var output: String
        var error: String
    }

    /// Like `run`, with the exit status and stderr; killed after `timeout`.
    static func execute(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval = 60) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        // Never wait on a credential prompt nobody can see.
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        // Output goes to files, not pipes: a full pipe can't stall the
        // child, and a grandchild holding one open can't stall us.
        let files = FileManager.default.temporaryDirectory
        let outURL = files.appendingPathComponent("muxy-\(UUID().uuidString).out")
        let errURL = files.appendingPathComponent("muxy-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
            return Result(status: -1, output: "", error: "")
        }
        defer {
            try? out.close()
            try? err.close()
        }
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        var status: Int32
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            status = -1
        } else {
            status = process.terminationStatus
        }
        let text = { (url: URL) in
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Result(status: status, output: text(outURL), error: text(errURL))
    }
}
