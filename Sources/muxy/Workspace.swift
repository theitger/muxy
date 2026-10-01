import SwiftUI
import Combine

/// One sidebar item — what used to be one Ghostty window: a set of tabs
/// that started in the same place. Everything shown about it is derived
/// from its first tab (usually the agent), never configured.
@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    /// The window this session lives in; changes when it's dragged elsewhere.
    var windowID: WindowModel.ID

    /// The shell a new window opens by itself — replaced if a folder
    /// arrives right after (see Store.openDirectory).
    var isLaunchDefault = false
    private let createdAt = Date()
    var age: TimeInterval { Date().timeIntervalSince(createdAt) }

    init(windowID: WindowModel.ID) {
        self.windowID = windowID
    }

    @Published var sessions: [TerminalSession] = [] {
        didSet { resubscribe() }
    }
    @Published var selectedSessionID: TerminalSession.ID?

    /// Session-level changes (attention, title, context) must repaint rows
    /// that only observe the workspace.
    private var cancellables: [AnyCancellable] = []

    private func resubscribe() {
        cancellables = sessions.map { session in
            session.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    var primary: TerminalSession? { sessions.first }

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var context: RepoContext {
        primary?.context ?? .plain(Paths.home)
    }

    var directory: String {
        primary?.cwd ?? Paths.home
    }

    /// Claude's conversation title when there is one, else the folder.
    var title: String {
        sessions.lazy.compactMap(\.agentTitle).first ?? context.shortFolder
    }

    /// Branch in a git checkout, the parent path anywhere else.
    var subtitle: String {
        context.repo != nil
            ? (context.branch ?? "detached")
            : Paths.abbreviate((directory as NSString).deletingLastPathComponent)
    }

    var groupName: String {
        context.repo ?? "Terminal"
    }

    var needsAttention: Bool {
        sessions.contains { $0.needsAttention }
    }

    var agent: AgentState {
        let states = sessions.map(\.agent)
        if states.contains(.blocked) { return .blocked }
        if states.contains(.working) { return .working }
        if states.contains(.idle) { return .idle }
        return .none
    }

    /// Something in this session is running (an agent at work, a command
    /// in a shell tab).
    var isBusy: Bool {
        sessions.contains { $0.isBusy }
    }

    var prStatus: PRStatus {
        switch context.checks {
        case .none: .none
        case .pending: .running
        case .passed: .ready
        case .failed: isBusy ? .fixing : .failed
        }
    }

    var searchText: String {
        [title, context.folder, context.repo ?? "", context.branch ?? "",
         context.pr.map { "#\($0)" } ?? "", directory].joined(separator: " ").lowercased()
    }
}
