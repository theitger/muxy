import Darwin
import Foundation

/// How a repository wants its worktrees set up, from `.wtconfig` in the main
/// checkout (git config format, section `[wt]`):
///
///     [wt]
///         base = development            branch new worktrees start from
///         env = .env                    copied, then given its own ports
///         copy = frontend/.env.local    more ignored files or folders to copy
///         port = SERVER_HOST_PORT       a free port, written into `env`
///         port = "PORT:3000"            a free port from 3000, into .wt.env
///         compose = true                its own Compose project name
///         bootstrap = "devbox run bootstrap"
///         teardown = "docker compose down"
///
/// Without one, a worktree is a plain checkout.
struct WorktreeRecipe {
    struct Port {
        var name: String
        /// Where to start looking; nil: the main checkout's own value.
        var start: Int?
    }

    var base: String?
    var env: String?
    var copies: [String] = []
    var ports: [Port] = []
    var compose = false
    var bootstrap: String?
    var teardown: String?
    /// Paths setup and builds make: never "work" that would be lost.
    var disposable: [String] = []

    static let file = ".wtconfig"
    /// Ports with their own start live here (direnv loads it, git ignores it).
    static let portsFile = ".wt.env"

    static func load(root: String) -> WorktreeRecipe? {
        let path = (root as NSString).appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: path),
              let output = Shell.run("/usr/bin/git", ["config", "-f", path, "--get-regexp", #"^wt\."#], in: root)
        else { return nil }
        var recipe = WorktreeRecipe()
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            switch pair[0] {
            case "wt.base": recipe.base = value
            case "wt.env": recipe.env = value
            case "wt.copy": recipe.copies.append(value)
            case "wt.compose": recipe.compose = ["true", "yes", "on", "1"].contains(value.lowercased())
            case "wt.bootstrap": recipe.bootstrap = value
            case "wt.teardown": recipe.teardown = value
            case "wt.disposable": recipe.disposable.append(value)
            case "wt.port":
                let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                guard Worktrees.isVariableName(parts[0]) else { continue }
                recipe.ports.append(Port(name: parts[0], start: parts.count > 1 ? Int(parts[1]) : nil))
            default: continue
            }
        }
        return recipe
    }
}

/// Worktrees that are ready to work in: local files copied, ports of their
/// own, dependencies installed. One spare per repository is kept ready in
/// the background, so starting a session doesn't wait for any of it.
enum Worktrees {
    /// Copies, ports, Compose project and bootstrap for a fresh worktree.
    /// Blocking. Throws only when bootstrap fails: the rest is best effort.
    static func setUp(_ path: String, root: String, recipe: WorktreeRecipe, progress: (String) -> Void) throws {
        for item in [recipe.env].compactMap({ $0 }) + recipe.copies {
            copy(item, from: root, to: path)
        }
        if let env = recipe.env {
            let file = (path as NSString).appendingPathComponent(env)
            var values = leasePorts(for: recipe, root: root, worktree: path).mapValues(String.init)
            if recipe.compose {
                values["COMPOSE_PROJECT_NAME"] = composeProject(root: root, worktree: path)
            }
            let inEnv = values.filter { name, _ in
                name == "COMPOSE_PROJECT_NAME" || recipe.ports.contains { $0.name == name && $0.start == nil }
            }
            write(inEnv, into: file)
            // URLs in it that name the old ports (a DSN, NEXTAUTH_URL, …)
            // follow, or the worktree would talk to the main checkout's.
            let before = read((root as NSString).appendingPathComponent(env))
            var moved: [String: String] = [:]
            for (name, value) in inEnv where name != "COMPOSE_PROJECT_NAME" {
                if let old = before[name], old != value { moved[old] = value }
            }
            retarget(moved, in: file)
            let own = values.filter { name, _ in recipe.ports.contains { $0.name == name && $0.start != nil } }
            if !own.isEmpty {
                write(own, into: (path as NSString).appendingPathComponent(WorktreeRecipe.portsFile))
            }
        }
        if let bootstrap = recipe.bootstrap {
            progress(L("Setting up: %@", bootstrap))
            let result = runInLoginShell(bootstrap, in: path, timeout: 1200)
            guard result.status == 0 else {
                let tail = (result.error.isEmpty ? result.output : result.error)
                    .split(separator: "\n").suffix(3).joined(separator: "\n")
                throw Launcher.Failure(message: L("%@ failed.", bootstrap) + (tail.isEmpty ? "" : "\n" + tail))
            }
        }
    }

    // MARK: Cleanup

    /// A checkout in `<root>/.worktrees/`: one muxy (or wt) made, and may
    /// remove again.
    static func isManaged(_ checkout: String, root: String) -> Bool {
        checkout.hasPrefix((root as NSString).appendingPathComponent(Launcher.worktreesFolder) + "/")
    }

    /// Nothing in it would be lost: no changes, no files git doesn't
    /// ignore (but the recipe's disposable ones), and no commit beyond `reference` (the merged PR's head, or
    /// where the branch started). Ignored files (copied env files, installed
    /// dependencies, build output) don't count. Blocking.
    static func isFinished(_ checkout: String, pullRequest: Int?, root: String) -> Bool {
        let git = "/usr/bin/git"
        let recipe = WorktreeRecipe.load(root: root)
        guard let status = Shell.run(git, ["status", "--porcelain", "--untracked-files=all"], in: checkout)
        else { return false }
        let disposable = recipe?.disposable ?? []
        // "XY path"; the first line comes trimmed, so split, don't count.
        let changed = status.split(separator: "\n").compactMap {
            $0.split(separator: " ", maxSplits: 1).last.map(String.init)
        }.filter { path in
            !disposable.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        guard changed.isEmpty else { return false }
        let reference: String
        if let pullRequest {
            // What GitHub merged, even when the agent's last push came from
            // somewhere else.
            guard Shell.execute(git, ["fetch", "--quiet", "origin", "refs/pull/\(pullRequest)/head"],
                                in: checkout, timeout: 30).status == 0 else { return false }
            reference = "FETCH_HEAD"
        } else {
            reference = Launcher.startPoint(in: root, recipe: recipe)
        }
        return Shell.run(git, ["rev-list", "--count", "\(reference)..HEAD"], in: checkout) == "0"
    }

    /// The recipe's teardown (Compose down, …), then the worktree and its
    /// branch. Blocking.
    static func remove(_ checkout: String, branch: String?, root: String) {
        let git = "/usr/bin/git"
        if let teardown = WorktreeRecipe.load(root: root)?.teardown {
            _ = runInLoginShell(teardown, in: checkout, timeout: 300)
        }
        guard Shell.execute(git, ["worktree", "remove", "--force", checkout], in: root).status == 0 else { return }
        if let branch {
            _ = Shell.execute(git, ["branch", "-D", branch], in: root)
        }
    }

    /// Your own shell runs setup commands, so they find what your terminal
    /// finds (devbox, pnpm, …).
    static func runInLoginShell(_ command: String, in directory: String, timeout: TimeInterval) -> Shell.Result {
        Shell.execute(Paths.userShell, ["-l", "-c", command], in: directory, timeout: timeout)
    }

    /// An ignored file or folder from the main checkout, unless the worktree
    /// already has it (tracked files win). APFS clones it: instant, no space.
    private static func copy(_ item: String, from root: String, to path: String) {
        guard !item.hasPrefix("/"), !item.split(separator: "/").contains("..") else { return }
        let source = (root as NSString).appendingPathComponent(item)
        let target = (path as NSString).appendingPathComponent(item)
        guard FileManager.default.fileExists(atPath: source),
              !FileManager.default.fileExists(atPath: target) else { return }
        try? FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? FileManager.default.copyItem(atPath: source, toPath: target)
    }

    // MARK: Ports

    /// A free port for each of the recipe's variables: not used by the main
    /// checkout or another worktree of the repository, and free right now.
    private static func leasePorts(for recipe: WorktreeRecipe, root: String, worktree: String) -> [String: Int] {
        guard !recipe.ports.isEmpty, let env = recipe.env else { return [:] }
        var taken = Set<Int>()
        for checkout in checkouts(of: root) where checkout != worktree {
            for file in [env, WorktreeRecipe.portsFile] {
                let values = read((checkout as NSString).appendingPathComponent(file))
                for port in recipe.ports { if let value = values[port.name].flatMap(Int.init) { taken.insert(value) } }
            }
        }
        let mine = read((root as NSString).appendingPathComponent(env))
        var leased: [String: Int] = [:]
        for port in recipe.ports {
            guard let start = port.start ?? mine[port.name].flatMap(Int.init) else { continue }
            var candidate = start + 1
            while candidate < 65535, taken.contains(candidate) || !isFree(candidate) {
                candidate += 1
            }
            guard candidate < 65535 else { continue }
            leased[port.name] = candidate
            taken.insert(candidate)
        }
        return leased
    }

    /// The main checkout and every worktree of the repository.
    static func checkouts(of root: String) -> [String] {
        guard let output = Shell.run("/usr/bin/git", ["worktree", "list", "--porcelain"], in: root) else { return [root] }
        return output.split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }

    /// Nothing listens there (any address, or localhost only).
    private static func isFree(_ port: Int) -> Bool {
        [INADDR_ANY, INADDR_LOOPBACK].allSatisfy { address in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port)).bigEndian
            addr.sin_addr.s_addr = in_addr_t(address).bigEndian
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
    }

    private static func composeProject(root: String, worktree: String) -> String {
        let name = (root as NSString).lastPathComponent + "-" + (worktree as NSString).lastPathComponent
        return String(name.lowercased().unicodeScalars.map {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) ? Character($0) : "-"
        })
    }

    // MARK: Env files

    static func isVariableName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// NAME=value pairs of a dotenv file (quotes dropped).
    static func read(_ file: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let (name, value) = assignment(String(line)) else { continue }
            values[name] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return values
    }

    private static func assignment(_ line: String) -> (String, String)? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("export ") { text = String(text.dropFirst("export ".count)) }
        guard let equals = text.firstIndex(of: "=") else { return nil }
        let name = text[..<equals].trimmingCharacters(in: .whitespaces)
        guard isVariableName(name) else { return nil }
        return (name, String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
    }

    /// `localhost:<old>` (subdomains too) and `127.0.0.1:<old>` → new port.
    private static func retarget(_ ports: [String: String], in file: String) {
        guard !ports.isEmpty, var text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        for (old, new) in ports {
            guard let regex = try? NSRegularExpression(pattern: #"((?:localhost|127\.0\.0\.1):)"# + old + #"(?!\d)"#)
            else { continue }
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1" + new
            )
        }
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Sets each value in place where the file has it, appends the rest.
    private static func write(_ values: [String: String], into file: String) {
        guard !values.isEmpty else { return }
        var lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var missing = values
        for index in lines.indices {
            guard let (name, _) = assignment(lines[index]), let value = values[name] else { continue }
            lines[index] = "\(name)=\(value)"
            missing[name] = nil
        }
        lines += missing.keys.sorted().map { "\($0)=\(missing[$0]!)" }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}
