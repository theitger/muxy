import Foundation

enum Git {
    /// Runs git synchronously. All muxy git calls are cheap metadata reads;
    /// they must never run on the main thread in hot paths — callers decide.
    @discardableResult
    static func run(_ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    struct Failure: Error {
        let text: String
    }

    /// Creates `<repo>.worktrees/<branch>`, reusing the branch when it exists.
    static func addWorktree(project: Project, branch: String) -> Result<String, Failure> {
        let container = project.path + ".worktrees"
        let target = container + "/" + branch
        try? FileManager.default.createDirectory(
            atPath: container, withIntermediateDirectories: true
        )
        let branchExists = run(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            in: project.path
        ) != nil
        let args = branchExists
            ? ["worktree", "add", target, branch]
            : ["worktree", "add", "-b", branch, target]
        guard runChecked(args, in: project.path) else {
            return .failure(Failure(text: "git worktree add ist fehlgeschlagen — existiert der Branch/Ordner schon?"))
        }
        return .success(target)
    }

    private static func runChecked(_ args: [String], in directory: String) -> Bool {
        run(args, in: directory) != nil
    }

    static func worktrees(of project: Project) -> [Worktree] {
        guard let output = run(["worktree", "list", "--porcelain"], in: project.path) else {
            return [Worktree(path: project.path, branch: "", projectPath: project.path)]
        }
        var result: [Worktree] = []
        var currentPath: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch "), let path = currentPath {
                let branch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
                result.append(Worktree(path: path, branch: branch, projectPath: project.path))
                currentPath = nil
            } else if line == "detached", let path = currentPath {
                result.append(Worktree(path: path, branch: "detached", projectPath: project.path))
                currentPath = nil
            }
        }
        return result
    }
}
