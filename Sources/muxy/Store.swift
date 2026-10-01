import SwiftUI

/// App-wide state: every session in every window, the agent-event channel,
/// shortcuts and the rules for moving sessions between windows.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var windows: [WindowModel] = []
    @AppStorage("sidebarVisible") var sidebarVisible = true
    @AppStorage("sidebarWidth") var sidebarWidth: Double = 256

    static let sidebarWidthRange: ClosedRange<Double> = 200 ... 420

    /// SwiftUI's window opener, captured from the first window's environment.
    var openWindow: OpenWindowAction?

    private var started = false
    private var keyMonitor: Any?
    private var hookWatcher: HookWatcher?
    private var prTimer: Timer?

    func toggleSidebar() {
        withAnimation(Theme.ease) { sidebarVisible.toggle() }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        installKeyMonitor()
        let watcher = HookWatcher(store: self)
        watcher.start()
        hookWatcher = watcher
        // PRs get opened and checks finish while you work — poll gently.
        prTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPullRequests() }
        }
    }

    func refreshPullRequests() {
        // The first tab speaks for the session — one gh call each.
        for workspace in workspaces {
            if let primary = workspace.primary, Git.mayHavePR(primary.context.branch) {
                primary.refreshContext()
            }
        }
    }

    // MARK: - Windows

    func window(_ id: WindowModel.ID?) -> WindowModel? {
        windows.first { $0.id == id }
    }

    func window(of workspace: Workspace) -> WindowModel? {
        window(workspace.windowID)
    }

    func window(for nsWindow: NSWindow?) -> WindowModel? {
        guard let nsWindow else { return nil }
        return windows.first { $0.nsWindow === nsWindow }
    }

    @discardableResult
    func makeWindow() -> WindowModel {
        let model = WindowModel()
        windows.append(model)
        return model
    }

    /// The window shortcuts and menu commands act on.
    var activeWindow: WindowModel? {
        window(for: NSApplication.shared.keyWindow)
            ?? window(for: NSApplication.shared.mainWindow)
            ?? windows.last { $0.nsWindow?.isVisible == true }
    }

    /// Menu/shortcut target; opens a window when none is left.
    private func targetWindow() -> WindowModel {
        if let active = activeWindow { return active }
        let model = makeWindow()
        openWindow?(id: "main", value: model.id)
        return model
    }

    /// ⇧⌘N — a new window with a fresh session, like ⌘N in Ghostty.
    func newWindow(directory: String = Paths.home) {
        let model = makeWindow()
        model.newWorkspace(directory: directory)
        openWindow?(id: "main", value: model.id)
    }

    /// Red button: the window's sessions end with it (confirmed if anything
    /// runs) — muxy itself keeps running, like Ghostty.
    func requestCloseWindow(_ model: WindowModel) {
        let owned = model.workspaces
        confirm(
            running: owned.flatMap(\.sessions).contains { $0.needsCloseConfirmation },
            title: "Fenster schließen?",
            detail: owned.count == 1
                ? "Die Session darin wird beendet."
                : "Die \(owned.count) Sessions darin werden beendet."
        ) {
            owned.forEach { $0.sessions.forEach { $0.terminate() } }
            self.workspaces.removeAll { $0.windowID == model.id }
            self.dropWindow(model)
            self.updateBadge()
        }
    }

    private func dropWindow(_ model: WindowModel) {
        let nsWindow = model.nsWindow
        windows.removeAll { $0.id == model.id }
        nsWindow?.close()
    }

    // MARK: - Workspaces

    func makeWorkspace(directory: String, in window: WindowModel) -> Workspace {
        let workspace = Workspace(windowID: window.id)
        add(TerminalSession(directory: directory), to: workspace)
        workspaces.append(workspace)
        return workspace
    }

    func add(_ session: TerminalSession, to workspace: Workspace) {
        session.onAttentionChange = { [weak self] in self?.updateBadge() }
        session.onContextChange = { [weak self] in self?.objectWillChange.send() }
        workspace.sessions.append(session)
        workspace.selectedSessionID = session.id
    }

    /// Visual order across all windows — ⌘J walks it.
    var orderedWorkspaces: [Workspace] {
        windows.flatMap(\.orderedWorkspaces)
    }

    func select(_ workspace: Workspace, session: TerminalSession? = nil) {
        guard let window = window(of: workspace) else { return }
        if let session { workspace.selectedSessionID = session.id }
        window.select(workspace)
        if window !== activeWindow { window.bringToFront() }
    }

    /// ⌘J — the next session that wants you (unseen news, or an agent
    /// still blocked on you), in any window, round-robin from the one in
    /// front. Says so when nobody is waiting.
    func jumpToAttention() {
        let ordered = orderedWorkspaces
        let current = activeWindow?.selectedWorkspaceID
        let start = ordered.firstIndex { $0.id == current } ?? -1
        for step in 0 ..< ordered.count {
            let workspace = ordered[(start + 1 + step + ordered.count) % ordered.count]
            if workspace.id == current { continue }
            if let session = workspace.sessions.first(where: { $0.needsAttention || $0.agent == .blocked }) {
                select(workspace, session: session)
                return
            }
        }
        activeWindow?.show("Gerade wartet keine Session")
    }

    /// Notification click.
    func focus(sessionID: String) {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id.uuidString == sessionID }) {
                select(workspace, session: session)
                window(of: workspace)?.bringToFront()
                return
            }
        }
    }

    func workspace(of session: TerminalSession) -> Workspace? {
        workspaces.first { $0.sessions.contains { $0.id == session.id } }
    }

    // MARK: - Closing

    private func closeWorkspace(_ workspace: Workspace) {
        let window = window(of: workspace)
        let index = window?.orderedWorkspaces.firstIndex { $0.id == workspace.id } ?? 0
        workspace.sessions.forEach { $0.terminate() }
        workspaces.removeAll { $0.id == workspace.id }
        window?.repairSelection(near: index)
        updateBadge()
    }

    func close(_ session: TerminalSession, in workspace: Workspace) {
        if workspace.sessions.count <= 1 {
            requestCloseWorkspace(workspace)
            return
        }
        confirm(
            running: session.needsCloseConfirmation,
            title: "\(session.tabTitle) schließen?",
            detail: "Der laufende Prozess in \(Paths.abbreviate(session.cwd)) wird beendet."
        ) {
            session.terminate()
            self.detach(session, from: workspace)
            self.updateBadge()
        }
    }

    func requestCloseWorkspace(_ workspace: Workspace) {
        confirm(
            running: workspace.sessions.contains { $0.needsCloseConfirmation },
            title: "\(workspace.title) schließen?",
            detail: "Alle Tabs in \(Paths.abbreviate(workspace.directory)) werden beendet."
        ) {
            self.closeWorkspace(workspace)
        }
    }

    /// ⌘Q — one keystroke must never silently kill every agent.
    func shouldQuit() -> Bool {
        let running = workspaces.flatMap(\.sessions).filter(\.needsCloseConfirmation)
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "muxy beenden?"
        alert.informativeText = running.count == 1
            ? "In einem Tab läuft noch etwas."
            : "In \(running.count) Tabs läuft noch etwas."
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
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

    // MARK: - Moving between windows

    /// Takes a tab out of its session, keeping the neighbour in front.
    private func detach(_ session: TerminalSession, from workspace: Workspace) {
        let index = workspace.sessions.firstIndex { $0.id == session.id } ?? 0
        workspace.sessions.removeAll { $0.id == session.id }
        if workspace.selectedSessionID == session.id, !workspace.sessions.isEmpty {
            workspace.selectedSessionID = workspace.sessions[max(index - 1, 0)].id
        }
    }

    /// A window emptied by a move has nothing left to confirm — it just goes.
    private func closeIfEmpty(_ window: WindowModel, near index: Int) {
        if window.workspaces.isEmpty {
            dropWindow(window)
        } else {
            window.repairSelection(near: index)
        }
    }

    /// A dragged tab was dropped. Outside every muxy window → it becomes
    /// its own window there. On another window, or on this window's
    /// sidebar → it becomes its own session in that window.
    func drop(_ session: TerminalSession, from workspace: Workspace, at point: NSPoint) {
        guard let source = window(of: workspace) else { return }
        let target = windowUnder(point)
        if target === source, !isOverSidebar(point, in: source) { return }
        if workspace.sessions.count == 1 {
            // The only tab is the whole session.
            drop(workspace, at: point)
            return
        }
        detach(session, from: workspace)
        let destination = target ?? makeWindow(at: point)
        let moved = Workspace(windowID: destination.id)
        add(session, to: moved)
        workspaces.append(moved)
        destination.select(moved)
        if target == nil {
            openWindow?(id: "main", value: destination.id)
        } else {
            destination.bringToFront()
        }
    }

    /// A dragged sidebar row was dropped: outside → own window, on another
    /// window → moves there.
    func drop(_ workspace: Workspace, at point: NSPoint) {
        guard let source = window(of: workspace) else { return }
        let target = windowUnder(point)
        if target === source { return }
        // Tearing the only session out of a window just moves the window.
        if target == nil, source.workspaces.count == 1, let nsWindow = source.nsWindow {
            nsWindow.setFrameTopLeftPoint(topLeft(for: point))
            return
        }
        let index = source.orderedWorkspaces.firstIndex { $0.id == workspace.id } ?? 0
        let destination = target ?? makeWindow(at: point)
        workspace.windowID = destination.id
        // Re-append so it lands at the end of the destination's list.
        workspaces.removeAll { $0.id == workspace.id }
        workspaces.append(workspace)
        destination.select(workspace)
        closeIfEmpty(source, near: index)
        if target == nil {
            openWindow?(id: "main", value: destination.id)
        } else {
            destination.bringToFront()
        }
    }

    private func makeWindow(at point: NSPoint) -> WindowModel {
        let model = makeWindow()
        model.pendingTopLeft = topLeft(for: point)
        return model
    }

    /// The new window appears under the pointer, grabbed near its top edge.
    private func topLeft(for point: NSPoint) -> NSPoint {
        NSPoint(x: point.x - 120, y: point.y + 20)
    }

    /// Topmost muxy window under a screen point.
    func windowUnder(_ point: NSPoint) -> WindowModel? {
        for nsWindow in NSApplication.shared.orderedWindows
            where nsWindow.isVisible && nsWindow.frame.contains(point) {
            if let model = window(for: nsWindow) { return model }
        }
        return nil
    }

    private func isOverSidebar(_ point: NSPoint, in window: WindowModel) -> Bool {
        guard sidebarVisible, let nsWindow = window.nsWindow else { return false }
        return nsWindow.convertPoint(fromScreen: point).x < sidebarWidth
    }

    // MARK: - Agent events

    /// Claude Code hook: `stop` (turn finished), `notify` (needs you),
    /// `prompt` (started working).
    func handleHookEvent(sessionUUID: String, event: String) {
        for workspace in workspaces {
            guard let session = workspace.sessions.first(where: { $0.id.uuidString == sessionUUID })
            else { continue }
            switch event {
            case "prompt":
                session.agent = .working
            case "notify":
                session.agent = .blocked
                session.markAttentionIfBackground(reason: "braucht dich")
            default:
                session.agent = .idle
                session.markAttentionIfBackground(reason: "ist fertig")
            }
            return
        }
    }

    func updateBadge() {
        // Attention lives on sessions; views that read it through the store
        // or a window (the header pill) need a nudge.
        objectWillChange.send()
        windows.forEach { $0.objectWillChange.send() }
        let count = workspaces.filter(\.needsAttention).count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Keyboard

    /// The ghostty surface consumes ⌘-keys before the menu sees them, so
    /// muxy's shortcuts are intercepted at the application level.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window?.attachedSheet == nil else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private enum KeyCode {
        static let tab: UInt16 = 48
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let digit = Int(key).flatMap { (1 ... 9).contains($0) ? $0 : nil }
        let window = self.window(for: event.window) ?? activeWindow

        switch (mods, event.keyCode) {
        case ([.command, .option], KeyCode.up): window?.selectWorkspace(offset: -1); return true
        case ([.command, .option], KeyCode.down): window?.selectWorkspace(offset: 1); return true
        case ([.control], KeyCode.tab): window?.selectTab(offset: 1); return true
        case ([.control, .shift], KeyCode.tab): window?.selectTab(offset: -1); return true
        default: break
        }
        if mods == .control, let digit {
            window?.selectWorkspace(index: digit - 1)
            return true
        }
        if mods == [.command, .shift] {
            switch key {
            case "n": newWindow()
            default: return false
            }
            return true
        }
        guard mods == .command else { return false }
        if let digit {
            window?.selectTab(index: digit - 1)
            return true
        }
        switch key {
        case "n": targetWindow().newWorkspace()
        case "t": targetWindow().newTab()
        case "w": window?.closeCurrent()
        case "j": jumpToAttention()
        case "k": window?.showSwitcher.toggle()
        case "b": toggleSidebar()
        default: return false
        }
        return true
    }

    // MARK: - Menu commands

    func newWorkspaceInFront() { targetWindow().newWorkspace() }
    func newTabInFront() { targetWindow().newTab() }

    /// `open -a Muxy <dir>`, `Scripts/muxy`, a folder dropped on the Dock
    /// icon: a new session there. The shell a fresh launch opened on its own
    /// makes way, so `muxy .` from a cold start shows exactly one session.
    func openDirectory(_ url: URL, in window: WindowModel) {
        var isDir: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let directory = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
        let placeholder = window.workspaces.count == 1
            ? window.workspaces.first.flatMap { $0.isLaunchDefault && $0.age < 3 ? $0 : nil }
            : nil
        window.newWorkspace(directory: directory)
        if let placeholder { closeWorkspace(placeholder) }
        window.bringToFront()
    }
}
