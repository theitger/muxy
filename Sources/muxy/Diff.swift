import Foundation

/// One file of a unified diff, read into lines with their numbers.
struct FileDiff: Identifiable, Equatable {
    enum Kind: Equatable {
        case added, deleted, modified, renamed, binary
    }

    struct Line: Equatable, Identifiable {
        enum Role: Equatable { case context, added, removed, hunk }
        var role: Role
        var text: String
        var old: Int?
        var new: Int?
        var index: Int
        var id: Int { index }
    }

    var path: String
    var oldPath: String?
    var kind: Kind
    var lines: [Line]
    var additions: Int
    var deletions: Int

    var id: String { path }
}

enum Diffs {
    /// Files that differ between two commits, `git diff` style. Blocking.
    static func load(from base: String, to commit: String, in checkout: String) -> [FileDiff] {
        let result = Shell.execute(
            WorkState.git,
            ["-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff", "-M", "-U3", base, commit],
            in: checkout, timeout: 60
        )
        guard result.status == 0 else { return [] }
        return parse(result.output)
    }

    /// `git diff` output → files.
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var old = 0
        var new = 0
        func flush() {
            if let file = current { files.append(file) }
            current = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flush()
                // "diff --git a/x b/x": the b side, unless a later header says.
                let path = line.components(separatedBy: " b/").last ?? line
                current = FileDiff(path: path, oldPath: nil, kind: .modified, lines: [], additions: 0, deletions: 0)
                continue
            }
            guard var file = current else { continue }
            defer { current = file }
            if file.lines.isEmpty || !line.hasPrefix(" ") && !line.hasPrefix("+") && !line.hasPrefix("-") && !line.hasPrefix("@@") && !line.hasPrefix("\\") {
                // Header lines before the first hunk.
                if line.hasPrefix("new file mode") { file.kind = .added; continue }
                if line.hasPrefix("deleted file mode") { file.kind = .deleted; continue }
                if line.hasPrefix("rename from ") { file.oldPath = String(line.dropFirst("rename from ".count)); file.kind = .renamed; continue }
                if line.hasPrefix("rename to ") { file.path = String(line.dropFirst("rename to ".count)); continue }
                if line.hasPrefix("Binary files ") { file.kind = .binary; continue }
                if line.hasPrefix("+++ ") {
                    let target = line.dropFirst(4)
                    if target.hasPrefix("b/") { file.path = String(target.dropFirst(2)) }
                    continue
                }
                if line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("similarity ") || line.hasPrefix("old mode") || line.hasPrefix("new mode") { continue }
            }
            if line.hasPrefix("@@") {
                if let match = line.groups(#"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#) {
                    old = Int(match[0]) ?? 0
                    new = Int(match[1]) ?? 0
                }
                file.lines.append(.init(role: .hunk, text: line, old: nil, new: nil, index: file.lines.count))
            } else if line.hasPrefix("+") {
                file.lines.append(.init(role: .added, text: String(line.dropFirst()), old: nil, new: new, index: file.lines.count))
                file.additions += 1
                new += 1
            } else if line.hasPrefix("-") {
                file.lines.append(.init(role: .removed, text: String(line.dropFirst()), old: old, new: nil, index: file.lines.count))
                file.deletions += 1
                old += 1
            } else if line.hasPrefix(" ") {
                file.lines.append(.init(role: .context, text: String(line.dropFirst()), old: old, new: new, index: file.lines.count))
                old += 1
                new += 1
            }
        }
        flush()
        return files
    }
}

/// A comment on one line of a diff, for the agent.
struct ReviewComment: Identifiable, Equatable {
    let id = UUID()
    var path: String
    /// The new file's line; the old one's for removed lines.
    var line: Int
    var removed: Bool
    var code: String
    var text: String
}

enum ReviewMessage {
    /// What the agent reads: each comment at its place, the line quoted.
    static func compose(_ comments: [ReviewComment]) -> String {
        var parts = [comments.count == 1 ? "A review comment on your changes:" : "Review comments on your changes:"]
        for (index, comment) in comments.enumerated() {
            let place = "\(comment.path):\(comment.line)" + (comment.removed ? " (a line you removed)" : "")
            parts.append("\(index + 1). \(place)\n   > \(comment.code.trimmingCharacters(in: .whitespaces))\n   \(comment.text)")
        }
        parts.append("Address each one. Say briefly what you changed for each.")
        return parts.joined(separator: "\n\n")
    }
}
