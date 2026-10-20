import Foundation

/// How much of each agent's plan is used, as the agents report it:
///
/// - Codex writes its rate limits into every session file
///   (~/.codex/sessions/…/rollout-*.jsonl, `rate_limits`).
/// - Claude Code hands them only to its status line command
///   (`rate_limits.five_hour` / `seven_day`, for Pro and Max plans). With
///   "Claude's limits in muxy" on, a small script in front of your status
///   line keeps the last input and then runs your status line as before.
///
/// The queue holds new starts for an agent whose limit is nearly used.
struct UsageWindow: Equatable {
    /// "5h", "week", …
    var name: String
    /// 0–100.
    var used: Double
    var resets: Date?
}

@MainActor
final class Usage: ObservableObject {
    static let shared = Usage()

    @Published private(set) var claude: [UsageWindow] = []
    @Published private(set) var codex: [UsageWindow] = []
    private var timer: Timer?

    /// At or above this, the queue starts nothing new for the agent.
    static let ceiling = 95.0

    /// What the status line script keeps.
    nonisolated static var claudeStatusFile: String { StateDirectory.installed + "/claude-status.json" }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Usage.shared.refresh() }
        }
        timer.tolerance = 10
        self.timer = timer
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let claude = Self.readClaude()
            let codex = Self.readCodex()
            await MainActor.run {
                if self.claude != claude { self.claude = claude }
                if self.codex != codex { self.codex = codex }
            }
        }
    }

    func windows(_ agent: AgentKind) -> [UsageWindow] {
        agent == .claude ? claude : codex
    }

    /// A limit of the agent is (nearly) used up: when it frees again.
    func exhausted(_ agent: AgentKind) -> UsageWindow? {
        windows(agent).filter { $0.used >= Self.ceiling && ($0.resets.map { $0 > Date() } ?? true) }
            .max { ($0.resets ?? .distantFuture) < ($1.resets ?? .distantFuture) }
    }

    // MARK: Reading (blocking)

    nonisolated static func readClaude(file: String = claudeStatusFile) -> [UsageWindow] {
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any]
        else { return [] }
        return claudeWindows(limits)
    }

    nonisolated static func claudeWindows(_ limits: [String: Any]) -> [UsageWindow] {
        [("five_hour", "5h"), ("seven_day", L("week"))].compactMap { key, name in
            guard let window = limits[key] as? [String: Any], let used = number(window["used_percentage"]) else { return nil }
            let resets = number(window["resets_at"] ?? window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(name: name, used: used, resets: resets)
        }
    }

    /// The newest Codex session file's last word on its limits.
    nonisolated static func readCodex(home: String = Paths.home + "/.codex") -> [UsageWindow] {
        let sessions = (home as NSString).appendingPathComponent("sessions")
        let calendar = Calendar.current
        var newest: (path: String, date: Date)?
        // Today's and the last days' folders: no need to walk years.
        for back in 0 ..< 7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = String(format: "%@/%04d/%02d/%02d", sessions, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
                let path = folder + "/" + name
                guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                if newest.map({ date > $0.date }) ?? true { newest = (path, date) }
            }
            if newest != nil { break }
        }
        guard let path = newest?.path, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let limits = find("rate_limits", in: json) as? [String: Any]
            else { continue }
            let windows = codexWindows(limits)
            if !windows.isEmpty { return windows }
        }
        return []
    }

    nonisolated static func codexWindows(_ limits: [String: Any]) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any], let used = number(window["used_percent"]) else { return nil }
            let minutes = number(window["window_minutes"]) ?? 0
            let name = minutes >= 10000 ? L("week") : minutes >= 60 ? "\(Int(minutes / 60))h" : "\(Int(minutes))m"
            return UsageWindow(name: name, used: used, resets: number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) })
        }
    }

    private nonisolated static func find(_ key: String, in value: Any) -> Any? {
        if let object = value as? [String: Any] {
            if let found = object[key] { return found }
            for child in object.values { if let found = find(key, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = find(key, in: child) { return found } }
        }
        return nil
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

/// The script in front of Claude Code's status line: keeps its input for
/// muxy, then runs the status line you had, unchanged.
enum ClaudeStatusTap {
    static var script: URL { URL(fileURLWithPath: Paths.home + "/.local/share/muxy/claude-statusline.sh") }
    static var settings: URL { URL(fileURLWithPath: Paths.home + "/.claude/settings.json") }

    static func isInstalled(settings: URL = settings, script: URL = script) -> Bool {
        (try? HookInstaller.statusLineCommand(in: settings)) == script.path
    }

    /// The status line command before muxy's, as the script remembers it.
    static func original(script: URL = script) -> String? {
        guard let text = try? String(contentsOf: script, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ORIGINAL=") }) else { return nil }
        return unquoted(String(line.dropFirst("ORIGINAL=".count)))
    }

    /// `statusFile`: where the input is kept (muxy's state folder).
    static func install(settings: URL = settings, script: URL = script, statusFile: String = Usage.claudeStatusFile) throws {
        guard !isInstalled(settings: settings, script: script) else { return }
        let current = try HookInstaller.statusLineCommand(in: settings) ?? ""
        let folder = (statusFile as NSString).deletingLastPathComponent
        let body = """
        #!/bin/sh
        # muxy keeps Claude Code's status line input (for its usage limits),
        # then runs your status line as before. Turned off in muxy's settings,
        # your status line comes back as it was.
        ORIGINAL=\(quoted(current))
        input=$(cat)
        mkdir -p \(quoted(folder)) && printf '%s' "$input" > \(quoted(statusFile)).$$ && mv -f \(quoted(statusFile)).$$ \(quoted(statusFile))
        [ -n "$ORIGINAL" ] && printf '%s' "$input" | sh -c "$ORIGINAL"
        exit 0

        """
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HookInstaller.installScript(Data(body.utf8), at: script)
        try HookInstaller.setStatusLine(command: script.path, in: settings)
    }

    static func uninstall(settings: URL = settings, script: URL = script) throws {
        guard isInstalled(settings: settings, script: script) else { return }
        let original = original(script: script) ?? ""
        try HookInstaller.setStatusLine(command: original.isEmpty ? nil : original, in: settings)
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func unquoted(_ text: String) -> String {
        guard text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 else { return text }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    }
}
