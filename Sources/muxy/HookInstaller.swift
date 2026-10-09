import Foundation

/// Puts muxy's agent hook into Claude Code's settings.json and Codex's
/// hooks.json, the way Scripts/install-claude-hook.sh and
/// install-codex-hook.sh do: muxy's entries are replaced, everything else
/// stays exactly as it is. Foundation only, so a test harness can compile
/// it on its own (Tests/hook-installer).
///
/// These files often live in a dotfiles repository behind a symlink, so a
/// write goes through the link, keeps the file's key order, indentation
/// and escapes, and happens only when muxy's entries actually differ.
enum HookInstaller {
    /// One hook entry: an agent event, an optional matcher, and the word
    /// agent-hook.sh gets for it.
    struct Hook: Equatable {
        var event: String
        var matcher: String?
        var argument: String
        var timeout: Int?
    }

    /// One agent's config file and the entries muxy wants in it.
    struct Target {
        var agent: String
        var file: URL
        var hooks: [Hook]
    }

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Some of muxy's entries are there, but not the current set.
        case outdated
        /// The file isn't JSON muxy can safely edit; it is left alone.
        case unreadable(String)
    }

    struct Failure: Error {
        let message: String
    }

    /// Notification types not listed (auth_success, quota_*, …) say
    /// nothing about whether Claude needs you.
    static let claudeHooks = [
        Hook(event: "SessionStart", argument: "start"),
        Hook(event: "UserPromptSubmit", argument: "prompt"),
        Hook(event: "PreToolUse", argument: "tool"),
        Hook(event: "Notification", matcher: "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", argument: "notify"),
        Hook(event: "Notification", matcher: "idle_prompt", argument: "idle"),
        Hook(event: "StopFailure", argument: "error"),
        Hook(event: "Stop", argument: "stop"),
    ]

    static let codexHooks = [
        Hook(event: "SessionStart", argument: "start", timeout: 10),
        Hook(event: "UserPromptSubmit", argument: "prompt", timeout: 10),
        Hook(event: "PreToolUse", argument: "tool", timeout: 10),
        Hook(event: "PostToolUse", argument: "tool", timeout: 10),
        Hook(event: "PermissionRequest", argument: "notify", timeout: 10),
        Hook(event: "Interrupt", argument: "idle", timeout: 10),
        Hook(event: "Stop", argument: "stop", timeout: 10),
    ]

    /// Commands that are muxy's, from any version: the old Claude-only
    /// hook and the current one, wherever they were installed from.
    static func isMuxyCommand(_ command: String) -> Bool {
        command.contains("claude-hook.sh") || command.contains("agent-hook.sh")
    }

    /// Where the hook script lives for every agent: outside any app bundle
    /// or checkout, so moving or updating muxy never breaks a settings file.
    static func scriptURL(home: URL) -> URL {
        home.appendingPathComponent(".local/share/muxy/agent-hook.sh")
    }

    // MARK: Status and install

    static func status(of target: Target, script: URL) -> Status {
        let root: JSON
        do {
            guard let parsed = try read(target.file) else { return .notInstalled }
            root = parsed
        } catch {
            return .unreadable((error as? Failure)?.message ?? error.localizedDescription)
        }
        let found = muxyEntries(in: root)
        if found.isEmpty { return .notInstalled }
        return found.sorted() == wantedEntries(target, script: script).sorted() ? .installed : .outdated
    }

    /// Replaces muxy's entries with the current set. Returns whether the
    /// file was written; an up-to-date file is never touched.
    @discardableResult
    static func install(_ target: Target, script: URL) throws -> Bool {
        var root = try read(target.file) ?? .object([])
        if muxyEntries(in: root).sorted() == wantedEntries(target, script: script).sorted() { return false }
        guard case var .object(members) = root else {
            throw Failure(message: "\(target.file.lastPathComponent) is not a JSON object.")
        }
        var hooks: [JSON.Member] = []
        let hooksIndex = members.firstIndex { $0.key == "hooks" }
        if let hooksIndex {
            guard case let .object(existing) = members[hooksIndex].value else {
                throw Failure(message: "\"hooks\" in \(target.file.lastPathComponent) is not an object.")
            }
            hooks = existing
        }

        // Out with muxy's old entries; an entry or event left empty by
        // that goes too, others stay as they are.
        for index in hooks.indices.reversed() {
            guard case let .array(entries) = hooks[index].value else { continue }
            var kept: [JSON] = []
            var changed = false
            for entry in entries {
                guard case var .object(fields) = entry,
                      let listIndex = fields.firstIndex(where: { $0.key == "hooks" }),
                      case let .array(list) = fields[listIndex].value
                else {
                    kept.append(entry)
                    continue
                }
                let others = list.filter { !isMuxyCommand($0["command"]?.stringValue ?? "") }
                if others.count == list.count {
                    kept.append(entry)
                    continue
                }
                changed = true
                if others.isEmpty { continue }
                fields[listIndex].value = .array(others)
                kept.append(.object(fields))
            }
            guard changed else { continue }
            if kept.isEmpty {
                hooks.remove(at: index)
            } else {
                hooks[index].value = .array(kept)
            }
        }

        // In with the current ones, after the user's own.
        for hook in target.hooks {
            let entry = entry(for: hook, target: target, script: script)
            if let index = hooks.firstIndex(where: { $0.key == hook.event }), case let .array(entries) = hooks[index].value {
                hooks[index].value = .array(entries + [entry])
            } else {
                hooks.append(JSON.Member(key: hook.event, value: .array([entry])))
            }
        }

        if let hooksIndex {
            members[hooksIndex].value = .object(hooks)
        } else {
            members.append(JSON.Member(key: "hooks", value: .object(hooks)))
        }
        root = .object(members)
        let original = try? String(contentsOf: resolved(target.file), encoding: .utf8)
        try write(root.formatted(like: original), to: target.file)
        return true
    }

    /// Copies the hook script to its stable place; returns whether it
    /// changed. Executable, since the agents run it directly.
    @discardableResult
    static func installScript(_ contents: Data, at url: URL) throws -> Bool {
        if (try? Data(contentsOf: url)) == contents, FileManager.default.isExecutableFile(atPath: url.path) {
            return false
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(contents, to: url, permissions: 0o755)
        return true
    }

    static func command(for hook: Hook, agent: String, script: URL) -> String {
        "\(shellQuoted(script.path)) \(hook.argument) \(agent)"
    }

    // MARK: Entries

    private static func entry(for hook: Hook, target: Target, script: URL) -> JSON {
        var command: [JSON.Member] = [
            JSON.Member(key: "type", value: .string("command")),
            JSON.Member(key: "command", value: .string(self.command(for: hook, agent: target.agent, script: script))),
        ]
        if let timeout = hook.timeout {
            command.append(JSON.Member(key: "timeout", value: .number(String(timeout))))
        }
        var fields: [JSON.Member] = []
        if let matcher = hook.matcher {
            fields.append(JSON.Member(key: "matcher", value: .string(matcher)))
        }
        fields.append(JSON.Member(key: "hooks", value: .array([.object(command)])))
        return .object(fields)
    }

    private static func wantedEntries(_ target: Target, script: URL) -> [String] {
        let root = JSON.object([JSON.Member(key: "hooks", value: .object(target.hooks.map {
            JSON.Member(key: $0.event, value: .array([entry(for: $0, target: target, script: script)]))
        }))])
        return muxyEntries(in: root)
    }

    /// Each muxy command in the file as one comparable line: event,
    /// matcher, how many hooks share its entry, and the hook itself.
    private static func muxyEntries(in root: JSON) -> [String] {
        guard case let .object(events)? = root["hooks"] else { return [] }
        var found: [String] = []
        for event in events {
            guard case let .array(entries) = event.value else { continue }
            for entry in entries {
                guard case let .array(list)? = entry["hooks"] else { continue }
                for hook in list where isMuxyCommand(hook["command"]?.stringValue ?? "") {
                    let matcher = entry["matcher"]?.stringValue ?? ""
                    found.append("\(event.key)\t\(matcher)\t\(list.count)\t\(hook.canonical)")
                }
            }
        }
        return found
    }

    // MARK: Files

    /// nil when the file doesn't exist or is empty.
    private static func read(_ url: URL) throws -> JSON? {
        let path = resolved(url).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw Failure(message: "Can't read \(url.lastPathComponent).")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        do {
            return try JSON.parse(text)
        } catch {
            throw Failure(message: "\(url.lastPathComponent) is not valid JSON.")
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url, permissions: nil)
    }

    /// Atomic and through symlinks: the new content goes to a temporary
    /// file beside the link's final target, then replaces that target in
    /// one rename. The link itself stays a link.
    private static func write(_ data: Data, to url: URL, permissions: Int?) throws {
        let fm = FileManager.default
        let target = resolved(url)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mode = permissions
            ?? ((try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int)
            ?? 0o644
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).muxy-\(getpid())-\(UInt32.random(in: 0 ... .max))")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw Failure(message: "Can't write \(target.path).")
        }
        if rename(temp.path, target.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temp)
            throw Failure(message: "Can't write \(target.path): \(reason)")
        }
    }

    /// The file a path finally points to, following every symlink on the
    /// way, including one at the end. Works for files that don't exist yet.
    static func resolved(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        for _ in 0 ..< 32 {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
            path = (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { break }
            path = destination.hasPrefix("/")
                ? destination
                : ((parent as NSString).appendingPathComponent(destination) as NSString).standardizingPath
        }
        return URL(fileURLWithPath: path)
    }

    /// Quoted for the shell only when it has to be (a space in the home
    /// folder's name), so the usual path reads plainly in the file.
    private static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+"))
        if text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - JSON that keeps its order

/// A JSON value that remembers key order and how strings and numbers were
/// written, so a file comes back byte for byte where muxy didn't change it.
indirect enum JSON: Equatable {
    case object([Member])
    case array([JSON])
    /// The decoded text, and the literal as it stood in the file.
    case string(String, raw: String? = nil)
    /// Kept as written: 1, 1.0 and 1e0 stay what they were.
    case number(String)
    case bool(Bool)
    case null

    struct Member: Equatable {
        var key: String
        var rawKey: String?
        var value: JSON

        init(key: String, rawKey: String? = nil, value: JSON) {
            self.key = key
            self.rawKey = rawKey
            self.value = value
        }

        static func == (a: Member, b: Member) -> Bool {
            a.key == b.key && a.value == b.value
        }
    }

    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.string(x, _), .string(y, _)): x == y
        case let (.number(x), .number(y)): x == y
        case let (.bool(x), .bool(y)): x == y
        case (.null, .null): true
        default: false
        }
    }

    subscript(key: String) -> JSON? {
        guard case let .object(members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var stringValue: String? {
        if case let .string(text, _) = self { return text }
        return nil
    }

    // MARK: Writing

    /// Pretty-printed in the file's own indentation (two spaces when there
    /// is no file yet), the layout Claude Code and Python's json module
    /// write, with the file's trailing newline or lack of it.
    func formatted(like original: String?) -> String {
        var unit = "  "
        var trailingNewline = true
        if let original {
            trailingNewline = original.hasSuffix("\n") || original.isEmpty
            for line in original.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                if !indent.isEmpty, indent.count < line.count {
                    unit = String(indent)
                    break
                }
            }
        }
        var out = ""
        write(to: &out, indent: unit, depth: 0)
        return trailingNewline ? out + "\n" : out
    }

    /// One line, keys sorted: for comparing values, not for files.
    var canonical: String {
        switch self {
        case let .object(members):
            "{" + members.sorted { $0.key < $1.key }
                .map { JSON.quoted($0.key) + ":" + $0.value.canonical }.joined(separator: ",") + "}"
        case let .array(items): "[" + items.map(\.canonical).joined(separator: ",") + "]"
        case let .string(text, _): JSON.quoted(text)
        case let .number(text): text
        case let .bool(value): value ? "true" : "false"
        case .null: "null"
        }
    }

    private func write(to out: inout String, indent: String, depth: Int) {
        let inner = String(repeating: indent, count: depth + 1)
        let outer = String(repeating: indent, count: depth)
        switch self {
        case let .object(members):
            if members.isEmpty {
                out += "{}"
                return
            }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += inner + (member.rawKey ?? JSON.quoted(member.key)) + ": "
                member.value.write(to: &out, indent: indent, depth: depth + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += outer + "}"
        case let .array(items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                item.write(to: &out, indent: indent, depth: depth + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += outer + "]"
        case let .string(text, raw):
            out += raw ?? JSON.quoted(text)
        case let .number(text):
            out += text
        case let .bool(value):
            out += value ? "true" : "false"
        case .null:
            out += "null"
        }
    }

    /// Escapes only what JSON requires; "/" and non-ASCII stay readable.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Reading

    struct ParseError: Error {
        let offset: Int
    }

    static func parse(_ text: String) throws -> JSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 512, index < bytes.count else { throw ParseError(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""):
                let (text, raw) = try string()
                return .string(text, raw: raw)
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return try number()
            }
        }

        private mutating func object(depth: Int) throws -> JSON {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object([])
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError(offset: index) }
                let (key, raw) = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError(offset: index) }
                index += 1
                skipWhitespace()
                members.append(Member(key: key, rawKey: raw, value: try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                } else {
                    throw ParseError(offset: index)
                }
            }
        }

        private mutating func array(depth: Int) throws -> JSON {
            index += 1
            var items: [JSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array([])
            }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError(offset: index) }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                } else {
                    throw ParseError(offset: index)
                }
            }
        }

        /// The decoded text and the literal, quotes included.
        private mutating func string() throws -> (String, String) {
            let start = index
            index += 1
            var scalars = String.UnicodeScalarView()
            var chunkStart = index
            func flush(_ end: Int) {
                scalars.append(contentsOf: String(decoding: bytes[chunkStart ..< end], as: UTF8.self).unicodeScalars)
            }
            while true {
                guard index < bytes.count else { throw ParseError(offset: index) }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flush(index)
                    index += 1
                    break
                }
                if byte < 0x20 { throw ParseError(offset: index) }
                guard byte == UInt8(ascii: "\\") else {
                    index += 1
                    continue
                }
                flush(index)
                index += 1
                guard index < bytes.count else { throw ParseError(offset: index) }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800 ..< 0xDC00).contains(code), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        if (0xDC00 ..< 0xE000).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw ParseError(offset: index)
                }
                chunkStart = index
            }
            let raw = String(decoding: bytes[start ..< index], as: UTF8.self)
            return (String(scalars), raw)
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[index ..< index + 4], as: UTF8.self), radix: 16)
            else { throw ParseError(offset: index) }
            index += 4
            return value
        }

        private mutating func number() throws -> JSON {
            let start = index
            let allowed = Set("+-0123456789.eE".utf8)
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start ..< index], as: UTF8.self)
            // Let Foundation judge the shape; the text stays as written.
            guard !text.isEmpty, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) is NSNumber
            else { throw ParseError(offset: start) }
            return .number(text)
        }

        private mutating func literal(_ word: String, _ value: JSON) throws -> JSON {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count, Array(bytes[index ..< index + utf8.count]) == utf8 else {
                throw ParseError(offset: index)
            }
            index += utf8.count
            return value
        }
    }
}
