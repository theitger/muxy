import Foundation

/// Watches ~/.local/state/muxy/events for files written by the agent hook
/// (Scripts/agent-hook.sh, for Claude Code and Codex). Each file is
/// "<muxy session> <agent> <event> <agent session id or -> [<transcript>]";
/// older hooks wrote no agent session id.
/// This is the deterministic "agent is working / done / needs input"
/// channel — no bell heuristics involved.
@MainActor
final class HookWatcher {
    static let eventsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/muxy/events")

    private weak var store: Store?
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(store: Store) {
        self.store = store
    }

    func start() {
        let dir = Self.eventsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
        drain()
    }

    private func drain() {
        let dir = Self.eventsDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        // Oldest first: a prompt followed by a stop must end as "idle".
        let ordered = files.compactMap { file -> (URL, Date)? in
            let url = dir.appendingPathComponent(file)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 < $1.1 }
        for (url, date) in ordered {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let event = Self.parse(content)
            let handled = event.map { store?.handleHookEvent($0) ?? false } ?? false
            // Another muxy instance may own the session — leave its events
            // to it; anything nobody picked up within a minute is litter.
            if handled || date.timeIntervalSinceNow < -60 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    struct Event {
        var session: String
        var agent: String
        var name: String
        var agentSession: String?
        var transcript: String?
    }

    static func parse(_ content: String) -> Event? {
        var parts = content.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let session = parts.first, !session.isEmpty else { return nil }
        // Old format: the transcript path (spaces and all) came fourth.
        if parts.count > 3, parts[3].hasPrefix("/") {
            parts = Array(parts[0 ..< 3]) + ["-", parts[3...].joined(separator: " ")]
        }
        func field(_ index: Int) -> String? {
            parts.count > index && !parts[index].isEmpty && parts[index] != "-" ? parts[index] : nil
        }
        return Event(
            session: session, agent: field(1) ?? "claude", name: field(2) ?? "stop",
            agentSession: field(3), transcript: field(4)
        )
    }
}
