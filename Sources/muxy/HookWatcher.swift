import Foundation

/// Watches ~/.local/state/muxy/events for files written by the Claude Code
/// hook (Scripts/claude-hook.sh). Each file is "<session-uuid> <event>".
/// This is the deterministic "agent is done / needs input" channel — no
/// bell heuristics involved.
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
        for file in files {
            let url = dir.appendingPathComponent(file)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: url)
            let parts = content.split(separator: " ").map(String.init)
            guard let uuid = parts.first, !uuid.isEmpty else { continue }
            let agent = parts.count > 1 ? parts[1].capitalized : nil
            store?.handleHookEvent(sessionUUID: uuid, agent: agent)
        }
    }
}
