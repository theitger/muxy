import SwiftUI

/// One muxy window: which of the app's sessions live in it and which one
/// is in front. Sessions themselves belong to the Store, so they can move
/// between windows without restarting anything.
@MainActor
final class WindowModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var selectedWorkspaceID: Workspace.ID?
    @Published var destination: WindowDestination = .home
    @Published var workSection: WorkSection = .terminal
    @Published var terminalFocus = false
    var isTerminalFocused: Bool { terminalFocus && destination == .workspace && workSection == .terminal }
    @Published var libraryPage = "board"
    /// A repository explicitly picked on Start wins over the previous task.
    @Published var newTaskDirectory: String?
    private var sections: [Workspace.ID: WorkSection] = [:]
    @Published var showSwitcher = false {
        didSet {
            if oldValue, !showSwitcher { focusTerminal() }
        }
    }
    /// ⌘N: the "what should happen?" panel.
    @Published var showNewSession = false {
        didSet {
            if oldValue, !showNewSession { focusTerminal() }
        }
    }

    /// ⇧⌘D: what the session in front changed (see ReviewView).
    @Published private(set) var review: ReviewModel?
    /// The hub over the stage: issues, sessions, worktrees (⌘H).
    var showHub: Bool {
        get { destination == .library }
        set {
            destination = newValue ? .library : (selectedWorkspace == nil ? .home : .workspace)
            if !newValue { focusTerminal() }
        }
    }

    func goHome() {
        review = nil
        taskTarget = nil
        reviewRun = nil
        destination = .home
    }

    func openLibrary(_ page: String = "board") {
        review = nil
        taskTarget = nil
        reviewRun = nil
        libraryPage = page
        destination = .library
    }

    func newTask(in directory: String? = nil) {
        newTaskDirectory = directory
        showNewSession = true
    }

    func showSection(_ section: WorkSection) {
        workSection = section
        if let selectedWorkspaceID { sections[selectedWorkspaceID] = section }
        if selectedWorkspace != nil { destination = .workspace }
        if section == .terminal { focusTerminal() }
    }

    func toggleTerminalFocus() {
        guard selectedWorkspace != nil else { return }
        showSection(.terminal)
        terminalFocus.toggle()
    }

    func openReview(_ workspace: Workspace? = nil, scope: ReviewModel.Scope = .lastTurn) {
        guard let workspace = workspace ?? selectedWorkspace else { return }
        guard let model = ReviewModel(workspace: workspace, scope: scope) else {
            show(L("Not a git checkout: nothing to review"))
            return
        }
        if workspace.id != selectedWorkspaceID { select(workspace) }
        showSection(.inspect)
        withAnimation(Theme.ease) { review = model }
    }

    func openAcceptance(_ workspace: Workspace? = nil) {
        guard let workspace = workspace ?? selectedWorkspace,
              workspace.context.checkout != nil, workspace.context.root != nil else {
            show(L("Not a git checkout: nothing to review"))
            return
        }
        openTask(TaskTarget(workspace: workspace), section: "implementation")
    }

    @Published var taskTarget: TaskTarget?
    @Published var taskSection = "overview"

    func openTask(_ target: TaskTarget, section: String = "overview") {
        review = nil
        reviewRun = nil
        if let workspace = TaskResolver.workspace(for: target) {
            if workspace.windowID != id, let owner = store.window(of: workspace) {
                owner.openTask(target, section: section)
                owner.bringToFront()
                return
            }
            select(workspace)
            taskSection = section
            showSection(section == "implementation" ? .inspect : section == "reviews" ? .quorum : section == "activity" ? .activity : .overview)
            return
        }
        taskTarget = target
        taskSection = section
        showHub = true
    }

    @Published var reviewRun: QuorumStatus?

    func openQuorumRun(_ status: QuorumStatus) {
        taskTarget = nil
        reviewRun = status
        libraryPage = "reviews"
        showHub = true
    }

    func closeReview() {
        withAnimation(Theme.ease) { review = nil }
        showSection(.terminal)
    }

    func toggleReview() {
        if review != nil { closeReview() } else { openReview() }
    }

    weak var nsWindow: NSWindow?
    /// A short message at the bottom of the window (e.g. "nobody waits").
    @Published private(set) var toast: String?
    private var toastToken = 0

    func show(_ message: String, seconds: Double = 1.6) {
        toastToken += 1
        let token = toastToken
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toast = nil
        }
    }
    /// A window view has taken this model (see WindowRoot).
    var claimed = false
    /// Where a dragged-out window should appear (screen frame).
    var pendingFrame: NSRect?

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
        if let selectedWorkspaceID { sections[selectedWorkspaceID] = workSection }
        selectedWorkspaceID = workspace.id
        workSection = sections[workspace.id] ?? .terminal
        taskTarget = nil
        reviewRun = nil
        destination = .workspace
        // Another session in front: its own changes, not the last one's.
        if let review, review.workspace.id != workspace.id { self.review = nil }
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
        if remaining.isEmpty { goHome() }
        else { workSection = selectedWorkspaceID.flatMap { sections[$0] } ?? .terminal }
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
        showSection(.terminal)
    }

    func selectTab(index: Int) {
        guard let workspace = selectedWorkspace,
              workspace.sessions.indices.contains(index) else { return }
        workspace.selectedSessionID = workspace.sessions[index].id
        showSection(.terminal)
    }

    func selectTab(offset: Int) {
        guard let workspace = selectedWorkspace, !workspace.sessions.isEmpty else { return }
        let count = workspace.sessions.count
        let current = workspace.sessions.firstIndex { $0.id == workspace.selectedSessionID } ?? 0
        workspace.selectedSessionID = workspace.sessions[(current + offset + count) % count].id
        showSection(.terminal)
    }

    /// ⌘W — close the current tab; the last tab closes the session.
    /// An empty window closes, like Ghostty's last tab.
    func closeCurrent() {
        if destination != .workspace {
            store.requestCloseWindow(self)
            return
        }
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
        guard destination == .workspace, workSection == .terminal,
              !showSwitcher, !showNewSession else { return }
        guard let view = selectedWorkspace?.selectedSession?.terminalView else { return }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}
