import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var projects: [Project] = []
    @Published var worktrees: [String: [Worktree]] = [:]
    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: Workspace.ID?
    @Published var showNewWorktreeSheet = false

    private var keyMonitor: Any?
    private var hookWatcher: HookWatcher?

    func startHookWatcher() {
        guard hookWatcher == nil else { return }
        let watcher = HookWatcher(store: self)
        watcher.start()
        hookWatcher = watcher
    }

    /// Agent hook fired for a session (done or needs input).
    func handleHookEvent(sessionUUID: String, agent: String?) {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id.uuidString == sessionUUID }) {
                session.markAttentionIfBackground(agent: agent)
                return
            }
        }
    }

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/muxy")
    static let projectsFile = configDir.appendingPathComponent("projects.txt")

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var adhocWorkspaces: [Workspace] {
        workspaces.filter { $0.worktree == nil }
    }

    // MARK: - Projects & worktrees

    func loadProjects() {
        ensureConfig()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let content = (try? String(contentsOf: Self.projectsFile, encoding: .utf8)) ?? ""
        var loaded: [Project] = []
        for rawLine in content.split(separator: "\n") {
            let withoutComment: Substring = rawLine.split(separator: "#").first ?? ""
            var path = withoutComment.trimmingCharacters(in: .whitespaces)
            if path.isEmpty { continue }
            if path.hasPrefix("~") {
                path = home + String(path.dropFirst())
            }
            if FileManager.default.fileExists(atPath: path) {
                loaded.append(Project(path: path))
            }
        }
        projects = loaded
        refreshWorktrees()
    }

    func refreshWorktrees() {
        let current = projects
        Task.detached(priority: .userInitiated) {
            var result: [String: [Worktree]] = [:]
            for project in current {
                result[project.path] = Git.worktrees(of: project)
            }
            let final = result
            await MainActor.run { self.worktrees = final }
        }
    }

    // MARK: - Workspaces (sidebar items)

    func workspace(for worktree: Worktree) -> Workspace? {
        workspaces.first { $0.worktree?.path == worktree.path }
    }

    /// Sidebar click: focus the workspace for this worktree or create one.
    func openWorktree(_ worktree: Worktree) {
        if let existing = workspace(for: worktree) {
            selectedWorkspaceID = existing.id
            return
        }
        let name = worktree.isMain
            ? (worktree.projectPath as NSString).lastPathComponent
            : worktree.name
        let workspace = Workspace(name: name, directory: worktree.path, worktree: worktree)
        addSession(to: workspace)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
    }

    /// ⌘N — a fresh terminal workspace in the home directory, like a new
    /// cmux window.
    func newTerminalWorkspace() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let count = adhocWorkspaces.count
        let workspace = Workspace(
            name: count == 0 ? "Terminal" : "Terminal \(count + 1)",
            directory: home,
            worktree: nil
        )
        addSession(to: workspace)
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
    }

    func closeWorkspace(_ workspace: Workspace) {
        workspace.sessions.forEach { $0.terminate() }
        workspaces.removeAll { $0.id == workspace.id }
        if selectedWorkspaceID == workspace.id {
            selectedWorkspaceID = workspaces.last?.id
        }
    }

    // MARK: - Tabs

    private func addSession(to workspace: Workspace) {
        let worktree = workspace.worktree ?? Worktree(
            path: workspace.directory,
            branch: "",
            projectPath: workspace.directory
        )
        let session = TerminalSession(worktree: worktree, agent: .shell)
        workspace.sessions.append(session)
        workspace.selectedSessionID = session.id
    }

    /// ⌘T — new tab inside the current workspace.
    func newTab() {
        guard let workspace = selectedWorkspace else {
            newTerminalWorkspace()
            return
        }
        addSession(to: workspace)
    }

    func selectTab(index: Int) {
        guard let workspace = selectedWorkspace,
              workspace.sessions.indices.contains(index) else { return }
        workspace.selectedSessionID = workspace.sessions[index].id
    }

    func close(_ session: TerminalSession, in workspace: Workspace) {
        if workspace.sessions.count <= 1 {
            confirmAndCloseWorkspace(workspace)
            return
        }
        confirm(
            running: session.needsCloseConfirmation,
            title: "\(session.name) schließen?",
            detail: "Die laufende Session in \(workspace.displayPath) wird beendet."
        ) {
            session.terminate()
            workspace.sessions.removeAll { $0.id == session.id }
            if workspace.selectedSessionID == session.id {
                workspace.selectedSessionID = workspace.sessions.last?.id
            }
        }
    }

    /// ⌘W — close the current tab; the last tab closes the sidebar item;
    /// nothing left to close quits muxy.
    func closeCurrent() {
        guard let workspace = selectedWorkspace else {
            NSApplication.shared.terminate(nil)
            return
        }
        guard let session = workspace.selectedSession else {
            confirmAndCloseWorkspace(workspace)
            return
        }
        close(session, in: workspace)
    }

    /// Sidebar ✕ / context menu: close the whole item, row disappears.
    func requestCloseWorkspace(_ workspace: Workspace) {
        confirmAndCloseWorkspace(workspace)
    }

    private func confirmAndCloseWorkspace(_ workspace: Workspace) {
        confirm(
            running: workspace.sessions.contains { $0.needsCloseConfirmation },
            title: "\(workspace.name) schließen?",
            detail: "Alle Sessions in \(workspace.displayPath) werden beendet."
        ) {
            self.closeWorkspace(workspace)
        }
    }

    private func confirm(running: Bool, title: String, detail: String, then action: @escaping () -> Void) {
        guard running else {
            action()
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Schließen")
        alert.addButton(withTitle: "Abbrechen")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    // MARK: - Keyboard

    /// The ghostty surface consumes ⌘-keys before the menu sees them, so
    /// muxy's shortcuts are intercepted at the application level.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }

            if mods == [.command, .shift], key == "n" {
                self.showNewWorktreeSheet = true
                return nil
            }
            guard mods == .command else { return event }
            switch key {
            case "t":
                self.newTab()
                return nil
            case "n":
                self.newTerminalWorkspace()
                return nil
            case "w":
                self.closeCurrent()
                return nil
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                self.selectTab(index: Int(key)! - 1)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Worktree creation (⌘⇧N)

    func createWorktree(project: Project, branch: String, onError: @escaping (String) -> Void) {
        let trimmed = branch.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let result = Git.addWorktree(project: project, branch: trimmed)
            await MainActor.run {
                switch result {
                case let .success(path):
                    self.refreshWorktrees()
                    self.openWorktree(
                        Worktree(path: path, branch: trimmed, projectPath: project.path)
                    )
                    self.showNewWorktreeSheet = false
                case let .failure(message):
                    onError(message.text)
                }
            }
        }
    }

    private func ensureConfig() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.configDir.path) {
            try? fm.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: Self.projectsFile.path) {
            let template = "# muxy projects — one absolute path per line, ~ allowed\n"
            try? template.write(to: Self.projectsFile, atomically: true, encoding: .utf8)
        }
    }
}
