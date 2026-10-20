import Foundation

/// Sessions that keep running while muxy quits, updates or crashes: with
/// it on, a tab's program runs under muxyd (Daemon/, Rust) and the tab
/// shows it through `muxyd attach`. Quitting muxy ends only that client;
/// the next launch attaches the tab to the same session again, with what
/// it printed meanwhile. A tab you close ends its session.
enum KeepAlive {
    static let key = "keepSessions"

    /// On, and muxyd is there.
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: key) && binary != nil
    }

    /// muxyd inside the app, or the checkout's build for a dev build.
    static var binary: String? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/muxyd").path
        if Paths.isApp { return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let built = repo.appendingPathComponent("Daemon/target/release/muxyd").path
        return FileManager.default.isExecutableFile(atPath: built) ? built : nil
    }

    static var socket: String { StateDirectory.path + "/muxyd.sock" }

    /// The line a tab runs: the session `id` attached, started with
    /// `command` (or your login shell) when it doesn't run yet.
    static func wrap(_ command: String?, id: UUID, directory: String) -> String? {
        guard let binary else { return nil }
        let inner = command ?? "exec \(Paths.userShell) -l"
        return [binary, "attach", "--socket", socket, "--id", id.uuidString, "--cwd", directory, "--", "/bin/sh", "-c", inner]
            .map(quoted).joined(separator: " ")
    }

    /// Ends a session for good (its tab was closed).
    static func kill(_ id: UUID) {
        guard let binary else { return }
        let socket = socket
        Task.detached(priority: .utility) {
            _ = Shell.execute(binary, ["kill", "--socket", socket, "--id", id.uuidString], in: Paths.home, timeout: 10)
        }
    }

    private static func quoted(_ text: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+=:"))
        if text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
