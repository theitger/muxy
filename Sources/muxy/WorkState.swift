import Foundation

/// A checkout's work as git objects, without touching the checkout: its
/// files as they are now (uncommitted changes and new files included,
/// ignored ones not) written as a commit on top of HEAD. Checkpoints, the
/// collision radar and proof all start from it. Blocking; call off the
/// main thread.
enum WorkState {
    static let git = "/usr/bin/git"

    struct Snapshot: Equatable {
        /// A commit whose parent is HEAD (or HEAD itself when nothing is
        /// uncommitted).
        var commit: String
        /// Its tree: equal trees, equal files.
        var tree: String
        var head: String
    }

    /// The working tree as a commit. Uses a copy of the real index, so git
    /// rehashes only what changed and the checkout's own staging stays.
    static func snapshot(of checkout: String, message: String = "muxy snapshot") -> Snapshot? {
        guard let head = Shell.run(git, ["rev-parse", "--verify", "HEAD"], in: checkout),
              let indexPath = Shell.run(git, ["rev-parse", "--path-format=absolute", "--git-path", "index"], in: checkout)
        else { return nil }
        let temp = indexPath + ".muxy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let fm = FileManager.default
        if fm.fileExists(atPath: indexPath) {
            guard (try? fm.copyItem(atPath: indexPath, toPath: temp)) != nil else { return nil }
        }
        let env = ["GIT_INDEX_FILE": temp]
        guard Shell.execute(git, ["add", "-A", "--", "."], in: checkout, timeout: 120, environment: env).status == 0
        else { return nil }
        let written = Shell.execute(git, ["write-tree"], in: checkout, timeout: 60, environment: env)
        guard written.status == 0, !written.output.isEmpty else { return nil }
        let tree = written.output
        // Nothing uncommitted: HEAD speaks for itself.
        if Shell.run(git, ["rev-parse", "HEAD^{tree}"], in: checkout) == tree {
            return Snapshot(commit: head, tree: tree, head: head)
        }
        let commit = Shell.execute(
            git, ["commit-tree", tree, "-p", head, "-m", message], in: checkout, timeout: 30,
            environment: identity
        )
        guard commit.status == 0, !commit.output.isEmpty else { return nil }
        return Snapshot(commit: commit.output, tree: tree, head: head)
    }

    /// commit-tree needs a name even where git has none configured.
    static let identity = [
        "GIT_AUTHOR_NAME": "muxy", "GIT_AUTHOR_EMAIL": "muxy@localhost",
        "GIT_COMMITTER_NAME": "muxy", "GIT_COMMITTER_EMAIL": "muxy@localhost"
    ]

    /// Paths that differ between two commits (or a commit and the working
    /// tree's snapshot).
    static func changedFiles(from base: String, to commit: String, in checkout: String) -> [String] {
        let result = Shell.execute(git, ["diff", "--name-only", "-z", base, commit], in: checkout, timeout: 60)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\0").map(String.init)
    }

    /// Where the branch left its base: the merge base with the start point
    /// new worktrees use (origin's default branch or the recipe's base).
    static func base(of checkout: String, root: String) -> String? {
        let start = Launcher.startPoint(in: root, recipe: WorktreeRecipe.load(root: root))
        return Shell.run(git, ["merge-base", "HEAD", start], in: checkout)
    }

    /// Files a real merge of `a` and `b` would conflict in, as git would
    /// merge them (`merge-tree --write-tree`, git ≥ 2.38): nothing is
    /// checked out. nil when git couldn't tell.
    static func conflicts(between a: String, and b: String, in directory: String) -> [String]? {
        let result = Shell.execute(
            git, ["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", a, b], in: directory, timeout: 60
        )
        switch result.status {
        // Clean.
        case 0: return []
        // Conflicts: the tree id, then each conflicted path.
        case 1:
            let fields = result.output.split(separator: "\0").map(String.init)
            var seen = Set<String>()
            return fields.dropFirst().filter { !$0.isEmpty && seen.insert($0).inserted }
        default: return nil
        }
    }
}
