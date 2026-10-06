import Foundation

/// The user's recent shell commands, newest first — the phone offers them
/// as suggestions while typing. Read from the login shell's own history
/// file (fish, zsh or bash), only its tail, re-read only when it changes.
@MainActor
enum ShellHistory {
    private static var cache: (path: String, modified: Date, commands: [String])?

    static func recent(limit: Int = 40) -> [String] {
        let shell = (Paths.userShell as NSString).lastPathComponent
        let home = Paths.home
        let path: String
        switch shell {
        case "fish": path = home + "/.local/share/fish/fish_history"
        case "zsh": path = ProcessInfo.processInfo.environment["HISTFILE"] ?? home + "/.zsh_history"
        default: path = home + "/.bash_history"
        }
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        else { return [] }
        if let cache, cache.path == path, cache.modified == modified { return cache.commands }

        let commands = unique(parse(tail(of: path), shell: shell).reversed(), limit: limit)
        cache = (path, modified, commands)
        return commands
    }

    private static func tail(of path: String, bytes: UInt64 = 256 * 1024) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if size > bytes, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }

    private static func parse(_ text: String, shell: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            switch shell {
            case "fish":
                guard line.hasPrefix("- cmd: ") else { return nil }
                return String(line.dropFirst(7))
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            case "zsh":
                // Extended format ": 1700000000:0;command", else plain.
                if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                    return String(line[line.index(after: semicolon)...])
                }
                return String(line)
            default:
                return line.hasPrefix("#") ? nil : String(line)
            }
        }
    }

    private static func unique(_ commands: some Sequence<String>, limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for command in commands {
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            // Single-line commands only — a suggestion chip can't show more.
            guard !trimmed.isEmpty, !trimmed.contains("\n"), trimmed.count <= 200, seen.insert(trimmed).inserted
            else { continue }
            out.append(trimmed)
            if out.count == limit { break }
        }
        return out
    }
}
