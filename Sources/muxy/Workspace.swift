import SwiftUI
import Combine

/// One sidebar item — cmux-style: a directory (worktree or ad-hoc) that
/// owns its tabs. The tab bar always shows only the active workspace's tabs.
@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let directory: String
    /// nil for ad-hoc terminals created with ⌘N.
    let worktree: Worktree?

    @Published var sessions: [TerminalSession] = [] {
        didSet { resubscribe() }
    }
    @Published var selectedSessionID: TerminalSession.ID?

    /// Session-level changes (attention, exit, title) must repaint rows
    /// that only observe the workspace.
    private var cancellables: [AnyCancellable] = []

    private func resubscribe() {
        cancellables = sessions.map { session in
            session.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    var anyAttention: Bool {
        sessions.contains { $0.needsAttention }
    }

    init(name: String, directory: String, worktree: Worktree?) {
        self.name = name
        self.directory = directory
        self.worktree = worktree
    }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var anyRunning: Bool {
        sessions.contains { $0.status.isRunning }
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return directory.hasPrefix(home) ? "~" + directory.dropFirst(home.count) : directory
    }
}
