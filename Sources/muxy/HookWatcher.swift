import Foundation

/// Watches ~/.local/state/muxy/events for files written by the Claude Code
/// hook (Scripts/claude-hook.sh). Each file is "<session-uuid> <agent> <event>".
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
        for (url, _) in ordered {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: url)
            let parts = content.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let uuid = parts.first, !uuid.isEmpty else { continue }
            store?.handleHookEvent(sessionUUID: uuid, event: parts.count > 2 ? parts[2] : "stop")
        }
    }
}
