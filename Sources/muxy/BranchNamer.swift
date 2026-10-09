import Foundation

/// Names a session's branch after its task, once the session already runs:
/// the task's first words make poor names ("gh issue 42 implement", a pasted
/// issue), so the smallest model of the agent you use reads it instead.
/// Blocking; call off the main thread.
enum BranchNamer {
    /// A neutral name a worktree starts on until the real one is known.
    static func placeholder(now: Date = Date()) -> String {
        let format = DateFormatter()
        format.dateFormat = "MMdd-HHmmss"
        return "session/" + format.string(from: now)
    }

    static func isPlaceholder(_ branch: String) -> Bool { branch.hasPrefix("session/") }

    /// A branch name for `task`, asked of `agent`'s smallest model (any
    /// installed one for a plain shell). A GitHub issue the task points to
    /// is looked up first, so its title and number end up in the name.
    static func suggest(for task: String, agent: AgentKind?, in directory: String) -> String? {
        var context = String(task.prefix(4000))
        let issue = issueNumber(in: task)
        var issueTitle: String?
        if let issue, let gh = Shell.find("gh") {
            issueTitle = Shell.run(gh, ["issue", "view", String(issue), "--json", "title", "-q", ".title"], in: directory)
            if let issueTitle { context = "GitHub issue #\(issue): \(issueTitle)\n\n" + context }
        }
        let question = """
        Name a git branch for this coding task. Reply with the branch name only: \
        lowercase English, a type prefix (feat/, fix/, chore/, docs/, refactor/, test/), \
        then 2 to 5 words joined by hyphens\(issue.map { ", starting with the issue number \($0)" } ?? "").

        Task:
        \(context)
        """
        let answer = ask(model(for: agent), prompt: question, in: directory)
        if let name = answer.flatMap(normalize), valid(name, in: directory) { return name }
        // No model to ask: the issue alone still names it well.
        if let issue, let issueTitle {
            let words = slug(issueTitle).split(separator: "-").prefix(5).joined(separator: "-")
            let name = "fix/\(issue)-\(words)"
            if valid(name, in: directory) { return name }
        }
        return nil
    }

    /// Renames the worktree's branch from its placeholder, unless it moved
    /// on: another branch checked out, or already pushed (a rename would
    /// orphan the remote branch and any PR on it).
    @discardableResult
    static func rename(in directory: String, from placeholder: String, to wanted: String) -> String? {
        let git = "/usr/bin/git"
        guard Shell.run(git, ["rev-parse", "--abbrev-ref", "HEAD"], in: directory) == placeholder,
              Shell.execute(git, ["rev-parse", "--abbrev-ref", "\(placeholder)@{upstream}"], in: directory).status != 0,
              Shell.execute(git, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(placeholder)"], in: directory).status != 0
        else { return nil }
        var name = wanted
        var suffix = 2
        while Shell.execute(git, ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: directory).status == 0 {
            name = "\(wanted)-\(suffix)"
            suffix += 1
        }
        guard Shell.execute(git, ["branch", "-m", placeholder, name], in: directory).status == 0 else { return nil }
        return name
    }

    // MARK: Models

    private enum Model {
        case claude(String)
        case codex(String, model: String?)
    }

    /// The agent you chose; for a plain shell whichever is installed.
    private static func model(for agent: AgentKind?) -> Model? {
        let order: [AgentKind] = agent.map { [$0] } ?? [.claude, .codex]
        for kind in order {
            switch kind {
            case .claude: if let path = Shell.find("claude") { return .claude(path) }
            case .codex: if let path = Shell.find("codex") { return .codex(path, model: codexSmallModel(path)) }
            }
        }
        return nil
    }

    private static func ask(_ model: Model?, prompt: String, in directory: String) -> String? {
        switch model {
        case let .claude(path):
            // No user settings: no hooks, no plugins. The login stays.
            let result = Shell.execute(
                path, ["-p", "--model", "haiku", "--no-session-persistence", "--setting-sources", "", prompt],
                in: directory, timeout: 40
            )
            return result.status == 0 ? result.output : nil
        case let .codex(path, small):
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("muxy-branch-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: out) }
            var args = ["exec"]
            if let small { args += ["-m", small] }
            args += ["-c", #"model_reasoning_effort="low""#, "--ephemeral", "--skip-git-repo-check",
                     "--ignore-rules", "-s", "read-only", "-o", out.path, prompt]
            guard Shell.execute(path, args, in: directory, timeout: 40).status == 0 else { return nil }
            return try? String(contentsOf: out, encoding: .utf8)
        case nil:
            return nil
        }
    }

    /// Codex's own list names its fast, cheap model ("Fast and affordable
    /// …"); the first listed one is the newest. Asked once per launch.
    private static let codexModelCache = Cache()

    private static func codexSmallModel(_ codex: String) -> String? {
        codexModelCache.value {
            let result = Shell.execute(codex, ["debug", "models"], in: Paths.home, timeout: 15)
            guard result.status == 0,
                  let data = result.output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else { return nil }
            return models
                .filter { ($0["visibility"] as? String) == "list" }
                .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
                .first { ($0["description"] as? String)?.lowercased().hasPrefix("fast") == true }?["slug"] as? String
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String??

        func value(_ make: () -> String?) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let stored { return stored }
            let made = make()
            stored = .some(made)
            return made
        }
    }

    // MARK: Text

    /// "#42", "issue 42", "issues/42": the issue a task points to.
    static func issueNumber(in task: String) -> Int? {
        let patterns = [#"github\.com/[^/\s]+/[^/\s]+/issues/(\d+)"#, #"(?i)\bissues?\s*#?(\d+)"#, #"(?<![\w&])#(\d+)\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: task, range: NSRange(task.startIndex..., in: task)),
                  let range = Range(match.range(at: 1), in: task)
            else { continue }
            return Int(task[range])
        }
        return nil
    }

    private static let types = ["feat", "fix", "chore", "docs", "refactor", "test"]

    /// Whatever the model said, as a clean `type/words` name.
    static func normalize(_ answer: String) -> String? {
        guard let line = answer.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty })
        else { return nil }
        var name = line.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "`'\"*. "))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        name = String(name.unicodeScalars.filter {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-/").contains($0)
        })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        if !name.contains("/") {
            // "fix-login-bug" → "fix/login-bug"
            let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
            if parts.count == 2, types.contains(parts[0]) {
                name = parts[0] + "/" + parts[1]
            } else {
                name = "feat/" + name
            }
        }
        name = String(name.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
        let words = name.split(separator: "/").last.map { $0.split(separator: "-").count } ?? 0
        return words == 0 ? nil : name
    }

    private static func slug(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.allSatisfy(\.isASCII) }
            .joined(separator: "-")
    }

    private static func valid(_ name: String, in directory: String) -> Bool {
        Shell.execute("/usr/bin/git", ["check-ref-format", "--branch", name], in: directory).status == 0
    }
}
