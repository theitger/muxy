import Foundation

/// What one turn of an agent left in its own log: its last words and the
/// last test run it started.
struct TurnRecord: Equatable {
    var summary: String?
    var tests: TestRun?
}

struct TestRun: Equatable {
    enum Outcome: Equatable {
        case passed
        case failed
        /// It ran, but its exit status says nothing (piped into `tail`,
        /// sent to the background).
        case unclear
    }

    var command: String
    var outcome: Outcome
}

/// Reads Claude's conversation log (~/.claude/projects/*/<id>.jsonl) and
/// Codex's rollout (~/.codex/sessions/**/rollout-*-<id>.jsonl) from the
/// end, one JSON object per line. Both formats change between versions:
/// anything unknown is skipped, nothing here throws.
enum Transcripts {
    /// The file's last `limit` bytes as lines; a line cut in half at the
    /// start is dropped. Logs grow to hundreds of megabytes, a turn rarely
    /// to more than a few.
    static func tail(of path: String, limit: Int = 8 << 20) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map(String.init)
    }

    /// The log of an agent conversation, found by its id when the hook
    /// never told (a session restored after a restart).
    static func locate(agent: AgentKind, conversation: String) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        switch agent {
        case .claude:
            let base = env["CLAUDE_CONFIG_DIR"] ?? Paths.home + "/.claude"
            let projects = base + "/projects"
            for folder in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let path = "\(projects)/\(folder)/\(conversation).jsonl"
                if fm.fileExists(atPath: path) { return path }
            }
            return nil
        case .codex:
            // sessions/YYYY/MM/DD/rollout-…-<id>.jsonl: newest days first.
            let sessions = (env["CODEX_HOME"] ?? Paths.home + "/.codex") + "/sessions"
            let sorted = { (path: String) in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted(by: >) }
            var days = 0
            for year in sorted(sessions) {
                for month in sorted("\(sessions)/\(year)") {
                    for day in sorted("\(sessions)/\(year)/\(month)") {
                        let folder = "\(sessions)/\(year)/\(month)/\(day)"
                        if let file = sorted(folder).first(where: { $0.hasSuffix("-\(conversation).jsonl") }) {
                            return "\(folder)/\(file)"
                        }
                        days += 1
                        if days > 60 { return nil }
                    }
                }
            }
            return nil
        }
    }

    // MARK: Claude

    /// The last turn of a Claude Code log: from the last prompt you typed
    /// to the end. Subagents' lines (sidechains) don't count.
    static func claudeTurn(_ lines: [String]) -> TurnRecord {
        var record = TurnRecord()
        var summaryMessage: String?
        var summaryDone = false
        var results: [String: (failed: Bool, background: Bool)] = [:]
        for line in lines.reversed() {
            guard let entry = object(line), entry["isSidechain"] as? Bool != true,
                  let type = entry["type"] as? String,
                  let message = entry["message"] as? [String: Any]
            else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if type == "user" {
                let toolResults = blocks.filter { $0["type"] as? String == "tool_result" }
                if !toolResults.isEmpty {
                    for result in toolResults {
                        guard let id = result["tool_use_id"] as? String else { continue }
                        let text = (result["content"] as? String) ?? ""
                        results[id] = (result["is_error"] as? Bool == true,
                                       text.hasPrefix("Command running in background"))
                    }
                    continue
                }
                // Reminders and the summary a compaction leaves are no prompt.
                if entry["isMeta"] as? Bool == true || entry["isCompactSummary"] as? Bool == true { continue }
                // A prompt: the turn began here.
                if message["content"] is String || blocks.contains(where: { $0["type"] as? String == "text" }) { break }
                continue
            }
            guard type == "assistant" else { continue }
            // One message arrives as several lines, one per block.
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let id = message["id"] as? String
            if !texts.isEmpty, !summaryDone {
                if record.summary == nil {
                    record.summary = texts.joined(separator: "\n")
                    summaryMessage = id
                } else if id != nil, id == summaryMessage {
                    record.summary = texts.joined(separator: "\n") + "\n" + (record.summary ?? "")
                } else {
                    summaryDone = true
                }
            }
            if record.tests == nil {
                for block in blocks.reversed() where block["type"] as? String == "tool_use" {
                    guard let input = block["input"] as? [String: Any], let command = input["command"] as? String,
                          let kind = testKind(command)
                    else { continue }
                    let result = (block["id"] as? String).flatMap { results[$0] }
                    let outcome: TestRun.Outcome
                    if result == nil || result?.background == true || input["run_in_background"] as? Bool == true {
                        outcome = .unclear
                    } else if result?.failed == true {
                        outcome = .failed
                    } else {
                        outcome = kind == .piped ? .unclear : .passed
                    }
                    record.tests = TestRun(command: command, outcome: outcome)
                    break
                }
            }
        }
        return record
    }

    // MARK: Codex

    /// The last turn of a Codex rollout: from its task_started (or your
    /// message) to the end. Commands come as exec_command_end events in
    /// older versions, as completed CommandExecution items in newer ones.
    static func codexTurn(_ lines: [String]) -> TurnRecord {
        var record = TurnRecord()
        var final: String?
        var fallback: String?
        var outputs: [String: String] = [:]
        func note(test command: String, exit: Int?) {
            guard record.tests == nil, let kind = testKind(command) else { return }
            let outcome: TestRun.Outcome = switch exit {
            case nil: .unclear
            case 0?: kind == .piped ? .unclear : .passed
            default: .failed
            }
            record.tests = TestRun(command: command, outcome: outcome)
        }
        scan: for line in lines.reversed() {
            guard let entry = object(line), let payload = entry["payload"] as? [String: Any] else { continue }
            let kind = payload["type"] as? String ?? ""
            switch (entry["type"] as? String ?? "", kind) {
            case ("event_msg", "task_started"), ("event_msg", "user_message"):
                break scan
            case ("event_msg", "task_complete"):
                if final == nil { final = nonEmpty(payload["last_agent_message"] as? String) }
            case ("event_msg", "agent_message"):
                let text = nonEmpty(payload["message"] as? String)
                if payload["phase"] as? String == "final_answer", final == nil { final = text }
                if fallback == nil { fallback = text }
            case ("response_item", "message"):
                guard payload["role"] as? String == "assistant" else { continue }
                let text = nonEmpty((payload["content"] as? [[String: Any]] ?? [])
                    .compactMap { $0["text"] as? String }.joined(separator: "\n"))
                if payload["phase"] as? String == "final_answer", final == nil { final = text }
                if fallback == nil { fallback = text }
            case ("event_msg", "item_completed"):
                guard let item = payload["item"] as? [String: Any] else { continue }
                switch item["type"] as? String {
                case "UserMessage":
                    break scan
                case "AgentMessage":
                    let text = nonEmpty((item["content"] as? [[String: Any]] ?? [])
                        .compactMap { $0["text"] as? String }.joined(separator: "\n"))
                    if fallback == nil { fallback = text }
                case "CommandExecution":
                    if let command = commandLine(item["command"]) { note(test: command, exit: integer(item["exit_code"])) }
                default:
                    continue
                }
            case ("event_msg", "exec_command_end"):
                if let command = commandLine(payload["command"]) { note(test: command, exit: integer(payload["exit_code"])) }
            case ("response_item", "function_call_output"):
                if let id = payload["call_id"] as? String { outputs[id] = payload["output"] as? String ?? "" }
            case ("response_item", "function_call"):
                // The oldest format: a "shell" call, its exit code in the output.
                guard ["shell", "local_shell", "container.exec"].contains(payload["name"] as? String ?? ""),
                      let arguments = (payload["arguments"] as? String).flatMap(object),
                      let command = commandLine(arguments["command"] ?? arguments["cmd"])
                else { continue }
                let output = (payload["call_id"] as? String).flatMap { outputs[$0] }
                note(test: command, exit: output.flatMap(exitCode))
            default:
                continue
            }
        }
        record.summary = final ?? fallback
        return record
    }

    // MARK: Tests

    enum TestKind: Equatable {
        case plain
        /// Its output goes on into another command: the exit status is
        /// that command's.
        case piped
    }

    /// Whether a shell command runs a test suite, and how much its exit
    /// status says. Looks at each command of a chain (`cd x && go test`).
    static func testKind(_ command: String) -> TestKind? {
        let pipefail = command.contains("pipefail")
        let pieces = command.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == ";" }
            .flatMap { $0.components(separatedBy: "&&") }
            .flatMap { $0.components(separatedBy: "||") }
        for piece in pieces {
            let stages = piece.components(separatedBy: "|")
            for (index, stage) in stages.enumerated() where isTestRunner(stage) {
                return index < stages.count - 1 && !pipefail ? .piped : .plain
            }
        }
        return nil
    }

    private static let prefixes = [
        #"^\(+\s*"#, #"^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|\S*)\s+"#,
        #"^(env|time|command|exec|nice|sudo|caffeinate(\s+-\w+)*)\s+"#, #"^g?timeout\s+\S+\s+"#,
    ]

    private static let runners = [
        #"^(swift|go|deno|dotnet|flutter|dart|mix|bazel|bazelisk|zig|bun) test\b"#,
        #"^cargo( \+\S+)? (test|nextest)\b"#,
        #"^(npm|pnpm|yarn)\b(?!.*\b(install|add|i|remove)\b).*\b(run )?test(:[\w:-]+)?(\s|$)"#,
        #"^((npx|bunx|pnpm exec|pnpm dlx|yarn) )?(jest|vitest|mocha|ava|playwright test|cypress run|karma start)\b"#,
        #"^(python3?( -m)? )?pytest\b"#, #"^python3? -m unittest\b"#,
        #"^(uv|poetry|pipenv|hatch|pdm) run (python3? -m )?(pytest|unittest)\b"#, #"^(tox|nox)\b"#,
        #"^(bundle exec )?(rspec|rails test|rake test|rake spec)\b"#,
        #"^(\./)?(gradlew|gradle)\b.*\b(test|check|\w+Test)\b"#, #"^(\./)?mvnw?\b.*\b(test|verify)\b"#,
        #"^make\b.*\b(test|tests|check)\b"#, #"^xcodebuild\b.*\btest\b"#, #"^ctest\b"#,
        #"^(\./)?(vendor/bin/)?(phpunit|pest)\b"#, #"^(composer|php artisan) test\b"#, #"^just\b.*\btest\b"#,
    ]

    private static func isTestRunner(_ stage: String) -> Bool {
        var text = stage.trimmingCharacters(in: .whitespaces)
        var stripped = true
        while stripped {
            stripped = false
            for prefix in prefixes {
                if let range = text.range(of: prefix, options: .regularExpression) {
                    text.removeSubrange(range)
                    stripped = true
                }
            }
        }
        return runners.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: Helpers

    private static func object(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// ["/bin/zsh", "-lc", "go test ./..."] → "go test ./...".
    static func commandLine(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let parts = value as? [String], !parts.isEmpty else { return nil }
        if parts.count >= 3, parts[0].hasSuffix("sh"), parts[1].hasPrefix("-"), parts[1].contains("c") {
            return parts.last
        }
        return parts.joined(separator: " ")
    }

    /// An old shell call's output: JSON with metadata.exit_code, or text
    /// that says it.
    private static func exitCode(_ output: String) -> Int? {
        if let json = object(output), let metadata = json["metadata"] as? [String: Any] {
            return integer(metadata["exit_code"])
        }
        return output.groups(#"(?:exited with code|Exit code:?)\s*(-?\d+)"#).flatMap { Int($0[0]) }
    }
}

/// The agent's markdown as one plain paragraph: what a card can show.
enum PlainText {
    static func from(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: #"(?s)```.*?(```|$)"#, with: "\n", options: .regularExpression)
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Tables and rules say nothing in one line.
            if line.isEmpty || line.hasPrefix("|") || line.range(of: #"^[-*_=]{3,}$"#, options: .regularExpression) != nil {
                continue
            }
            var heading = false
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(range)
                heading = true
            }
            var item = false
            for pattern in [#"^>\s?"#, #"^([-*+•]|\d+[.)])\s+"#, #"^\[[ xX]\]\s+"#] {
                if let range = line.range(of: pattern, options: .regularExpression) {
                    line.removeSubrange(range)
                    item = item || pattern != #"^>\s?"#
                }
            }
            line = inline(line).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if heading || item, let last = line.last, !".!?:;".contains(last) {
                line += heading ? ":" : "."
            }
            lines.append(line)
        }
        text = lines.joined(separator: " ")
        for (dash, replacement) in [(" — ", ", "), ("—", ", "), (" – ", ", ")] {
            text = text.replacingOccurrences(of: dash, with: replacement)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// At most `limit` characters, cut after a sentence when one ends late
    /// enough, else after a word.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let ends = [". ", "! ", "? "].compactMap { head.range(of: $0, options: .backwards)?.lowerBound }
        if let end = ends.max(), head.distance(from: head.startIndex, to: end) > limit * 2 / 5 {
            return String(head[...end])
        }
        let words = head.range(of: " ", options: .backwards).map { String(head[..<$0.lowerBound]) } ?? head
        return words.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + " …"
    }

    private static func inline(_ line: String) -> String {
        var text = line
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "$1"),
            (#"`([^`]+)`"#, "$1"),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }
}
