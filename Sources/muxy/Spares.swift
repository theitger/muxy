import Foundation

/// One worktree per repository, checked out and set up ahead of time
/// (detached, on the start branch): a new session takes it and only creates
/// its branch, so it starts at once even where a checkout and bootstrap take
/// half a minute. Remembered in `.git/muxy-spare`, so it survives restarts.
final class Spares: @unchecked Sendable {
    static let shared = Spares()

    private let lock = NSLock()
    /// Spares being made, by main checkout.
    private var making: [String: Task<Void, Never>] = [:]
    /// A failed spare isn't retried for a while (a broken bootstrap would
    /// otherwise run on every ⌘N).
    private var failedAt: [String: Date] = [:]

    private static let git = "/usr/bin/git"

    /// Starts making a spare for `root` unless one is ready or on its way.
    func prepare(root: String) {
        lock.lock()
        defer { lock.unlock() }
        guard making[root] == nil,
              Self.stored(root: root) == nil,
              failedAt[root].map({ Date().timeIntervalSince($0) > 600 }) ?? true
        else { return }
        // A spare an earlier muxy was still making when it quit: half done.
        if let stale = Self.unfinished(root: root) {
            _ = Shell.execute(Self.git, ["worktree", "remove", "--force", stale], in: root)
            try? FileManager.default.removeItem(atPath: Self.marker(root))
        }
        // Another muxy is making one right now.
        if (try? String(contentsOfFile: Self.marker(root), encoding: .utf8))?.hasPrefix("making ") == true { return }
        making[root] = Task.detached(priority: .utility) { [weak self] in
            let made = Self.make(root: root)
            self?.finish(root: root, made: made)
        }
    }

    private func finish(root: String, made: String?) {
        lock.lock()
        defer { lock.unlock() }
        making[root] = nil
        if let made {
            try? made.write(toFile: Self.marker(root), atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: Self.marker(root))
            failedAt[root] = Date()
        }
    }

    /// The spare, once it is ready (waits for one on its way), handed over:
    /// nil when there is none or it isn't fit to use anymore.
    func take(root: String) async -> String? {
        let pending = lock.withLock { making[root] }
        await pending?.value
        return lock.withLock {
            guard let path = Self.stored(root: root) else { return nil }
            try? FileManager.default.removeItem(atPath: Self.marker(root))
            // Nobody took it meanwhile: still detached. (Files its bootstrap
            // touched don't matter: the taker resets it when it's behind.)
            guard Shell.execute(Self.git, ["symbolic-ref", "--quiet", "HEAD"], in: path).status != 0 else { return nil }
            return path
        }
    }

    private static func marker(_ root: String) -> String {
        (root as NSString).appendingPathComponent(".git/muxy-spare")
    }

    /// The recorded spare, if it is ready and its folder is still a
    /// worktree of `root`. The marker reads "<path>" when ready and
    /// "making <pid> <path>" while it is being made.
    private static func stored(root: String) -> String? {
        guard let text = try? String(contentsOfFile: marker(root), encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("making "), Worktrees.checkouts(of: root).contains(path) else { return nil }
        return path
    }

    /// Left half made by a muxy that is gone (another one running may
    /// still be at it).
    private static func unfinished(root: String) -> String? {
        guard let text = try? String(contentsOfFile: marker(root), encoding: .utf8),
              text.hasPrefix("making ") else { return nil }
        let parts = text.dropFirst("making ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pid = Int32(parts[0]), kill(pid, 0) != 0 else { return nil }
        return parts[1]
    }

    /// Blocking: checkout plus setup. nil when anything failed (and
    /// nothing is left behind).
    private static func make(root: String) -> String? {
        let recipe = WorktreeRecipe.load(root: root)
        let start = Launcher.startPoint(in: root, recipe: recipe)
        let path = Launcher.freeFolder(in: root, named: "session-" + stamp())
        try? "making \(getpid()) \(path)".write(toFile: marker(root), atomically: true, encoding: .utf8)
        guard Shell.execute(git, ["worktree", "add", "--quiet", "--detach", path, start], in: root).status == 0 else {
            return nil
        }
        guard let recipe else { return path }
        do {
            try Worktrees.setUp(path, root: root, recipe: recipe) { _ in }
            return path
        } catch {
            _ = Shell.execute(git, ["worktree", "remove", "--force", path], in: root)
            return nil
        }
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "MMdd-HHmmss"
        return format.string(from: Date())
    }
}
