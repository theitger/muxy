import Foundation

/// What a session's card in the wings shows of its terminal: the last lines
/// of real output, without an agent's input box and footer, plus the
/// agent's own progress line ("Testing resume… (1m 12s · esc to interrupt)").
struct Snapshot: Equatable {
    var lines: [String]
    /// The agent's spinner line, shortened to what it is doing.
    var activity: String?

    static let lineCount = 4

    /// `text` is the terminal's active area as `TerminalSurface.readText`
    /// returns it.
    static func make(from text: String, columns: Int) -> Snapshot {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingTrailingWhitespace() }
        // Claude Code frames its input between two full-width rules a few
        // lines apart; from the upper one down is input box and footer, not
        // output. A lone rule opens a dialog — that is content and stays.
        let rules = lines.indices.filter { isRule(lines[$0]) }
        if rules.count >= 2 {
            let upper = rules[rules.count - 2], lower = rules[rules.count - 1]
            if lower - upper <= 8, lines.count - lower <= 8 {
                lines.removeSubrange(upper...)
            }
        }
        var activity: String?
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isRule(line) { continue }
            // Right-aligned hints (Claude's "◐ medium · /effort").
            if columns > 0, line.count - trimmed.count > columns * 2 / 5 { continue }
            // Below an agent's progress line is only its input and footer.
            if let spinner = spinnerText(trimmed) {
                activity = spinner
                break
            }
            output.append(trimmed)
        }
        return Snapshot(lines: Array(output.suffix(lineCount)), activity: activity)
    }

    /// A horizontal rule or box edge: mostly box-drawing characters.
    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 12 else { return false }
        let drawing = chars.filter { "─━═╭╮╰╯┌┐└┘".contains($0) }.count
        return drawing * 10 >= chars.count * 9
    }

    /// An agent's progress line: Claude's "✢ Pollinating…" (a spinner glyph,
    /// a verb, an ellipsis) or anything ending in "esc to interrupt" (Codex's
    /// "• Working (48s • esc to interrupt)"). Claude's "✻ Crunched for 1s"
    /// has no ellipsis — the turn is over.
    private static func spinnerText(_ line: String) -> String? {
        let claude = line.first.map { "·✢✳✶✻✽*".contains($0) } == true && line.contains("…")
        guard claude || line.contains("esc to interrupt") else { return nil }
        var text = line.drop { !$0.isLetter }
        if let paren = text.firstIndex(of: "(") { text = text[..<paren] }
        let result = text.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var copy = self
        while copy.last?.isWhitespace == true { copy.removeLast() }
        return copy
    }
}

#if DEBUG
/// MUXY_DEBUG_SNAPSHOTS=<file>: every read and what the card made of it.
@MainActor
enum SnapshotLog {
    private static let path = ProcessInfo.processInfo.environment["MUXY_DEBUG_SNAPSHOTS"]

    static func write(session: TerminalSession, raw: String, snapshot: Snapshot) {
        guard let path else { return }
        let entry = """
        ===== \(session.tabTitle) agent=\(session.agent) kind=\(session.kind?.rawValue ?? "-") \(Date())
        \(raw)
        ----- activity=\(snapshot.activity ?? "nil")
        \(snapshot.lines.joined(separator: "\n"))

        """
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(entry.utf8))
        }
    }
}
#endif
