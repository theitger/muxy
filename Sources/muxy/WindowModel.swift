import SwiftUI

/// One muxy window: which of the app's sessions live in it and which one
/// is in front. Sessions themselves belong to the Store, so they can move
/// between windows without restarting anything.
@MainActor
final class WindowModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var selectedWorkspaceID: Workspace.ID?
    @Published var showSwitcher = false {
        didSet {
            if oldValue, !showSwitcher { focusTerminal() }
        }
    }

    weak var nsWindow: NSWindow?
    /// A short message at the bottom of the window (e.g. "nobody waits").
    @Published private(set) var toast: String?
    private var toastToken = 0

    func show(_ message: String) {
        toastToken += 1
        let token = toastToken
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toast = nil
        }
    }
    /// A window view has taken this model (see WindowRoot).
    var claimed = false
    /// Where a torn-off window should appear (screen point, top-left).
    var pendingTopLeft: NSPoint?

    private var store: Store { .shared }

    var workspaces: [Workspace] {
        store.workspaces.filter { $0.windowID == id }
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    // MARK: - Groups

    struct Group: Identifiable {
        let name: String
        let workspaces: [Workspace]
        var id: String { name }
    }

    /// Sidebar sections by repository, in order of first appearance.
    var groups: [Group] {
        var order: [String] = []
        var members: [String: [Workspace]] = [:]
        for workspace in workspaces {
            let name = workspace.groupName
            if members[name] == nil { order.append(name) }
            members[name, default: []].append(workspace)
        }
        return order.map { Group(name: $0, workspaces: members[$0] ?? []) }
    }

    /// Visual order — what ⌃1…9 and ⌘⌥↑/↓ walk through.
    var orderedWorkspaces: [Workspace] {
        groups.flatMap(\.workspaces)
    }

    /// Sessions anywhere in muxy that want you — except the one in front here.
    var attentionWorkspaces: [Workspace] {
        store.orderedWorkspaces.filter { $0.needsAttention && $0.id != selectedWorkspaceID }
    }

    // MARK: - Sessions

    /// ⌘N — a fresh shell in home (or `directory`), its own sidebar item.
    func newWorkspace(directory: String = Paths.home) {
        let workspace = store.makeWorkspace(directory: directory, in: self)
        select(workspace)
    }

    func select(_ workspace: Workspace) {
        selectedWorkspaceID = workspace.id
    }

    func selectWorkspace(index: Int) {
        let ordered = orderedWorkspaces
        guard ordered.indices.contains(index) else { return }
        select(ordered[index])
    }

    func selectWorkspace(offset: Int) {
        let ordered = orderedWorkspaces
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedWorkspaceID } ?? 0
        select(ordered[(current + offset + ordered.count) % ordered.count])
    }

    /// After a session left this window: keep a neighbour in front.
    func repairSelection(near index: Int) {
        guard selectedWorkspace == nil else { return }
        let remaining = orderedWorkspaces
        selectedWorkspaceID = remaining.isEmpty ? nil : remaining[min(max(index, 0), remaining.count - 1)].id
    }

    // MARK: - Tabs

    /// ⌘T — new tab where the current tab is, like Ghostty.
    func newTab() {
        guard let workspace = selectedWorkspace else {
            newWorkspace()
            return
        }
        let directory = workspace.selectedSession?.cwd ?? workspace.directory
        store.add(TerminalSession(directory: directory), to: workspace)
    }

    func selectTab(index: Int) {
        guard let workspace = selectedWorkspace,
              workspace.sessions.indices.contains(index) else { return }
        workspace.selectedSessionID = workspace.sessions[index].id
    }

    func selectTab(offset: Int) {
        guard let workspace = selectedWorkspace, !workspace.sessions.isEmpty else { return }
        let count = workspace.sessions.count
        let current = workspace.sessions.firstIndex { $0.id == workspace.selectedSessionID } ?? 0
        workspace.selectedSessionID = workspace.sessions[(current + offset + count) % count].id
    }

    /// ⌘W — close the current tab; the last tab closes the session.
    /// An empty window closes, like Ghostty's last tab.
    func closeCurrent() {
        guard let workspace = selectedWorkspace else {
            store.requestCloseWindow(self)
            return
        }
        guard let session = workspace.selectedSession else {
            store.requestCloseWorkspace(workspace)
            return
        }
        store.close(session, in: workspace)
    }

    // MARK: - Focus

    func bringToFront() {
        nsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Hand keyboard focus back to the visible terminal (after the switcher).
    func focusTerminal() {
        guard let view = selectedWorkspace?.selectedSession?.terminalView else { return }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}
