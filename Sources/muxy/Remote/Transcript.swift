import Foundation

/// Claude Code's conversation log (one JSON object per line) turned into
/// what the phone's chat shows. The format is Claude Code's internal one,
/// not an API: anything unexpected is skipped, never fatal — the terminal
/// view stays as the fallback.
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

        var items: [[String: Any]] = []
        var toolIndex: [String: Int] = [:]
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  entry["isSidechain"] as? Bool != true,
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
                        items.append(["kind": "claude", "text": text])
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
        return Array(items.suffix(maxItems))
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

    private static func output(_ content: Any?) -> [String] {
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
        return out.count > 24 ? Array(out.prefix(24)) + [["sign": " ", "text": "… \(out.count - 24) more lines"]] : out
    }
}
