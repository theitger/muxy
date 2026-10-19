import Foundation

/// An agent's conversation log (one JSON object per line), Claude Code's or
/// Codex's, turned into what the phone's chat shows. Both formats are the
/// agents' internal ones, not an API: anything unexpected is skipped, never
/// fatal; the terminal view stays as the fallback.
enum Transcript {
    /// Only the log's tail is read — logs grow to many megabytes.
    static let tailBytes = 3 * 1024 * 1024
    static let maxItems = 80

    static func items(at path: String) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line
        let entries = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        // Codex wraps every line as {type, payload}.
        if entries.contains(where: { $0["payload"] is [String: Any] }) {
            return Array(codex(entries).suffix(maxItems))
        }
        return Array(claude(entries).suffix(maxItems))
    }

    private static func claude(_ entries: [[String: Any]]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        var toolIndex: [String: Int] = [:]
        for entry in entries {
            guard entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any]
            else { continue }
            let type = entry["type"] as? String
            let isMeta = entry["isMeta"] as? Bool == true

            if let text = message["content"] as? String {
                if type == "user", !isMeta, let prompt = userPrompt(text) {
                    items.append(["kind": "user", "text": prompt])
                }
                continue
            }
            guard let parts = message["content"] as? [[String: Any]] else { continue }
            for part in parts {
                switch (type, part["type"] as? String) {
                case ("assistant", "text"):
                    if let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(["kind": "agent", "text": text])
                    }
                case ("assistant", "tool_use"):
                    guard let id = part["id"] as? String, let name = part["name"] as? String else { continue }
                    let input = part["input"] as? [String: Any] ?? [:]
                    var item: [String: Any] = ["kind": "tool", "id": id, "tool": name, "target": target(name, input)]
                    if let diff = diff(name, input) { item["diff"] = diff }
                    toolIndex[id] = items.count
                    items.append(item)
                case ("user", "tool_result"):
                    guard let id = part["tool_use_id"] as? String, let index = toolIndex[id] else { continue }
                    items[index]["output"] = output(part["content"])
                    items[index]["error"] = part["is_error"] as? Bool == true
                    items[index]["done"] = true
                case ("user", "text"):
                    if !isMeta, let text = part["text"] as? String, let prompt = userPrompt(text) {
                        items.append(["kind": "user", "text": prompt])
                    }
                default:
                    break
                }
            }
        }
        return items
    }

    /// Codex's rollout. Newer versions log each finished item
    /// (`item_completed`: your message, its answers, commands, file
    /// changes); older ones loose events. The newer form wins when present,
    /// the log holds both kinds of line otherwise twice.
    private static func codex(_ entries: [[String: Any]]) -> [[String: Any]] {
        let events = entries.compactMap { entry -> [String: Any]? in
            entry["type"] as? String == "event_msg" ? entry["payload"] as? [String: Any] : nil
        }
        let itemized = events.contains { $0["type"] as? String == "item_completed" }
        var items: [[String: Any]] = []
        func text(_ content: Any?) -> String {
            ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        func command(_ id: String, _ line: Any?, output: String?, exit: Int?) {
            items.append([
                "kind": "tool", "id": id, "tool": "Shell",
                "target": String((Transcripts.commandLine(line) ?? "").replacingOccurrences(of: Paths.home, with: "~").prefix(300)),
                "output": self.output(output), "error": (exit ?? 0) != 0, "done": true,
            ])
        }
        for (index, event) in events.enumerated() {
            let id = "codex-\(index)"
            switch event["type"] as? String {
            case "item_completed" where itemized:
                guard let item = event["item"] as? [String: Any] else { continue }
                switch item["type"] as? String {
                case "UserMessage":
                    if let prompt = codexPrompt(text(item["content"])) { items.append(["kind": "user", "text": prompt]) }
                case "AgentMessage":
                    let said = text(item["content"])
                    if !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(["kind": "agent", "text": said])
                    }
                case "CommandExecution":
                    command(item["id"] as? String ?? id, item["command"],
                            output: item["aggregated_output"] as? String, exit: item["exit_code"] as? Int)
                case "FileChange":
                    let changes = item["changes"] as? [String: [String: Any]] ?? [:]
                    for (path, change) in changes.sorted(by: { $0.key < $1.key }) {
                        var tool: [String: Any] = [
                            "kind": "tool", "id": "\(item["id"] as? String ?? id)-\(path)",
                            "tool": change["type"] as? String == "add" ? "Write" : "Edit",
                            "target": path.replacingOccurrences(of: Paths.home, with: "~"),
                            "done": true, "error": item["status"] as? String == "failed",
                        ]
                        if let diff = unified(change["unified_diff"] as? String ?? change["content"] as? String) {
                            tool["diff"] = diff
                        }
                        items.append(tool)
                    }
                default:
                    continue
                }
            case "user_message" where !itemized:
                if let prompt = codexPrompt(event["message"] as? String ?? "") { items.append(["kind": "user", "text": prompt]) }
            case "agent_message" where !itemized:
                if let said = event["message"] as? String, !said.isEmpty { items.append(["kind": "agent", "text": said]) }
            case "exec_command_end" where !itemized:
                command(event["call_id"] as? String ?? id, event["command"],
                        output: event["aggregated_output"] as? String ?? event["stdout"] as? String,
                        exit: event["exit_code"] as? Int)
            default:
                continue
            }
        }
        return items
    }

    /// Your messages; the instructions Codex puts in front (AGENTS.md,
    /// environment) are its own plumbing.
    private static func codexPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") || trimmed.hasPrefix("# AGENTS.md") { return nil }
        return trimmed
    }

    /// A unified diff (or a new file's content) as signed lines, capped.
    private static func unified(_ text: String?) -> [[String: String]]? {
        guard let text, !text.isEmpty else { return nil }
        var out: [[String: String]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") || line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            switch line.first {
            case "+": out.append(["sign": "+", "text": String(line.dropFirst())])
            case "-": out.append(["sign": "-", "text": String(line.dropFirst())])
            case " ": out.append(["sign": " ", "text": String(line.dropFirst())])
            default: if !line.isEmpty { out.append(["sign": "+", "text": String(line)]) }
            }
        }
        return capped(out)
    }

    private static func capped(_ out: [[String: String]]) -> [[String: String]] {
        out.count > 24 ? Array(out.prefix(24)) + [["sign": " ", "text": "… \(out.count - 24) more lines"]] : out
    }

    /// Typed prompts only — slash-command wrappers, reminders and
    /// interrupt notices are Claude Code's own plumbing.
    private static func userPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") || trimmed.hasPrefix("[Request interrupted") { return nil }
        return trimmed
    }

    private static func target(_ tool: String, _ input: [String: Any]) -> String {
        let keys = ["command", "file_path", "pattern", "url", "query", "description", "prompt", "path"]
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty {
                let short = value.replacingOccurrences(of: Paths.home, with: "~")
                return String(short.prefix(300))
            }
        }
        return ""
    }

    static func output(_ content: Any?) -> [String] {
        var text = ""
        if let string = content as? String {
            text = string
        } else if let parts = content as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count <= 12 { return lines }
        return Array(lines.prefix(10)) + ["… \(lines.count - 10) more lines"]
    }

    /// Edit/Write as removed and added lines, capped.
    private static func diff(_ tool: String, _ input: [String: Any]) -> [[String: String]]? {
        func lines(_ key: String) -> [String] {
            (input[key] as? String)?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        }
        var out: [[String: String]] = []
        switch tool {
        case "Edit":
            out = lines("old_string").map { ["sign": "-", "text": $0] } + lines("new_string").map { ["sign": "+", "text": $0] }
        case "Write":
            out = lines("content").map { ["sign": "+", "text": $0] }
        default:
            return nil
        }
        return capped(out)
    }
}
