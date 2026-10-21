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
    /// Agents started by "New Session" skip their permission prompts.
    @AppStorage("skipPermissions") var skipPermissions = true
    /// Sessions come back after a quit, a crash or an update.
    @AppStorage("restoreSessions") var restoreOnLaunch = true

    static let sidebarWidthRange: ClosedRange<Double> = 200 ... 420

    /// SwiftUI's window opener, captured from the first window's environment.
    var openWindow: OpenWindowAction?
    var openSettings: OpenSettingsAction?

    private var started = false
    private var keyMonitor: Any?
    private var hookWatcher: HookWatcher?
    private var prTimer: Timer?
    private var snapshotTimer: Timer?
    private var saveTimer: Timer?
    private var portTimer: Timer?
    /// Nothing is saved before the last launch's sessions had their
    /// chance to come back: the first window's fresh shell would erase them.
    private var restoreAttempted = false
    private var saved: SavedSessions?

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
        CommandCenter.shared.start(store: self)
        RemoteServer.shared.startIfEnabled()
        StayAwake.shared.start()
        QuorumWatch.shared.start()
        Radar.shared.start()
        HubModel.shared.start()
        Queue.shared.resume()
        Landing.shared.resume()
        WorkLedger.shared.start()
        Usage.shared.start()
        // Restored sessions: what was proven on their files before.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Proofs.shared.recall(self.workspaces.compactMap(\.context.checkout))
        }
        // PRs get opened and checks finish while you work — poll gently.
        prTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPullRequests() }
        }
        let snapshots = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshots() }
        }
        // Lets macOS coalesce the wakeup with others.
        snapshots.tolerance = 0.3
        snapshotTimer = snapshots
        // Folders and conversations change all the time; a crash must not
        // lose more than a few seconds of them.
        let saves = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveSessions() }
        }
        saves.tolerance = 1
        saveTimer = saves
        // Which servers each session runs (Open app).
        let ports = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Previews.shared.scan(self.workspaces)
            }
        }
        ports.tolerance = 1
        portTimer = ports
        #if DEBUG
        launchDebugSessions()
        #endif
    }

    #if DEBUG
    /// MUXY_DEBUG_LAUNCH="claude|/dir|prompt|branch;codex|/dir||" — sessions
    /// to open on launch, for trying the app without clicking. Branch "auto":
    /// a placeholder, renamed after the prompt.
    private func launchDebugSessions() {
        guard let list = ProcessInfo.processInfo.environment["MUXY_DEBUG_LAUNCH"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = self.windows.first else { return }
            for entry in list.split(separator: ";") {
                let field = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard field.count >= 2 else { continue }
                let spec = SessionSpec(
                    directory: field[1], agent: AgentKind(rawValue: field[0]),
                    prompt: field.count > 2 ? field[2] : "",
                    branch: field.count > 3 && !field[3].isEmpty
                        ? (field[3] == "auto" ? BranchNamer.placeholder() : field[3]) : nil,
                    autoName: field.count > 3 && field[3] == "auto"
                )
                self.launch(spec, in: window)
            }
        }
    }
    #endif

    /// The wings' live lines: one text read per card, only for windows on
    /// screen.
    func refreshSnapshots() {
        #if DEBUG
        // Debugging: every running session, seen or not.
        if ProcessInfo.processInfo.environment["MUXY_DEBUG_SNAPSHOTS"] != nil {
            workspaces.flatMap(\.sessions).forEach { $0.refreshSnapshot() }
            return
        }
        #endif
        // Codex without muxy's hook: its state is read off its screen,
        // always, seen or not.
        for session in workspaces.flatMap(\.sessions) where session.kind == .codex && !session.reportsByHook {
            session.refreshSnapshot()
        }
        guard sidebarVisible else { return }
        for window in windows {
            guard let nsWindow = window.nsWindow, nsWindow.occlusionState.contains(.visible) else { continue }
            // The one on stage too: its card keeps its size and lines.
            for workspace in window.workspaces {
                if let featured = workspace.featured, featured.kind != .codex || featured.reportsByHook {
                    featured.refreshSnapshot()
                }
            }
        }
    }

    func refreshPullRequests() {
        guard !Git.rateLimited else { return }
        // The first tab speaks for the session; one gh call per repository
        // answers all of its sessions at once.
        let primaries = workspaces.compactMap(\.primary).filter { Git.mayHavePR($0.context.branch) }
        let byRepo = Dictionary(grouping: primaries) { $0.context.root ?? $0.cwd }
        for (root, sessions) in byRepo {
            guard sessions.count > 1, sessions.first?.context.root != nil else {
                sessions.forEach { $0.refreshContext() }
                continue
            }
            let branches = Set(sessions.compactMap(\.context.branch))
            Task.detached(priority: .utility) {
                let answers = Git.pullRequests(in: root, branches: branches)
                await MainActor.run {
                    for session in sessions {
                        guard let branch = session.context.branch, let lookup = answers?[branch],
                              // Mergeability still computing: the single lookup asks again.
                              !Self.stillComputing(lookup)
                        else {
                            session.refreshContext()
                            continue
                        }
                        session.refreshContext(known: (branch, lookup))
                    }
                }
            }
        }
    }

    private nonisolated static func stillComputing(_ lookup: Git.Lookup) -> Bool {
        if case let .found(pr) = lookup { return pr.state == .open && pr.mergeability == .unknown }
        return false
    }

    // MARK: - Restore

    /// The last launch's sessions, into `first` and as many more windows as
    /// there were. False when there was nothing to bring back.
    @discardableResult
    func restoreSessions(into first: WindowModel) -> Bool {
        guard !restoreAttempted else { return false }
        restoreAttempted = true
        guard restoreOnLaunch, let state = SavedSessions.load() else { return false }
        var restoredAny = false
        for savedWindow in state.windows {
            let window = restoredAny ? makeWindow() : first
            var made: [Workspace?] = []
            for savedWorkspace in savedWindow.workspaces {
                let tabs = savedWorkspace.tabs.map { $0.session() }
                guard let head = tabs.compactMap({ $0 }).first else {
                    made.append(nil)
                    continue
                }
                let workspace = makeWorkspace(directory: head.cwd, in: window, session: head)
                workspace.quorumReference = savedWorkspace.quorumReference
                tabs.compactMap { $0 }.dropFirst().forEach { add($0, to: workspace) }
                if let index = savedWorkspace.selected, tabs.indices.contains(index), let tab = tabs[index] {
                    workspace.selectedSessionID = tab.id
                }
                made.append(workspace)
            }
            let present = made.compactMap { $0 }
            guard let fallback = present.first else {
                if window !== first { windows.removeAll { $0.id == window.id } }
                continue
            }
            let chosen = savedWindow.selected.flatMap { made.indices.contains($0) ? made[$0] : nil }
            window.select(chosen ?? fallback)
            if window !== first { openWindow?(id: "main", value: window.id) }
            restoredAny = true
        }
        saved = state
        return restoredAny
    }

    /// Every window's sessions as they are now.
    private var currentSessions: SavedSessions {
        SavedSessions(windows: windows.compactMap { window in
            let ordered = window.orderedWorkspaces
            var list: [SavedSessions.Workspace] = []
            var selected: Int?
            for workspace in ordered {
                let pairs = workspace.sessions.compactMap { session in
                    SavedSessions.Tab(session).map { (session.id, $0) }
                }
                guard !pairs.isEmpty else { continue }
                if workspace.id == window.selectedWorkspaceID { selected = list.count }
                list.append(SavedSessions.Workspace(
                    tabs: pairs.map(\.1),
                    selected: pairs.firstIndex { $0.0 == workspace.selectedSessionID },
                    quorumReference: workspace.quorumReference
                ))
            }
            return list.isEmpty ? nil : SavedSessions.Window(workspaces: list, selected: selected)
        })
    }

    /// Writes the sessions when they changed since the last write.
    func saveSessions() {
        guard restoreAttempted else { return }
        let state = currentSessions
        guard state != saved else { return }
        state.write()
        saved = state
    }

    /// Something worth keeping changed (a conversation began or ended):
    /// saved right away rather than on the next tick.
    func sessionsChanged() {
        DispatchQueue.main.async { self.saveSessions() }
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

    /// A new window starts at Start; explicit directory opens still start work.
    func newWindow(directory: String? = nil) {
        let model = makeWindow()
        if let directory { model.newWorkspace(directory: directory) }
        openWindow?(id: "main", value: model.id)
    }

    /// Red button: the window's sessions end with it (confirmed if anything
    /// runs) — muxy itself keeps running, like Ghostty.
    func requestCloseWindow(_ model: WindowModel) {
        let owned = model.workspaces
        confirm(
            running: owned.flatMap(\.sessions).contains { $0.needsCloseConfirmation },
            title: L("Close window?"),
            detail: owned.count == 1
                ? L("The session in it will end.")
                : L("The %d sessions in it will end.", owned.count)
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

    func makeWorkspace(directory: String, in window: WindowModel, session: TerminalSession? = nil) -> Workspace {
        let workspace = Workspace(windowID: window.id)
        add(session ?? TerminalSession(directory: directory), to: workspace)
        workspaces.append(workspace)
        return workspace
    }

    func add(_ session: TerminalSession, to workspace: Workspace) {
        session.onAttentionChange = { [weak self] in self?.updateBadge() }
        session.onContextChange = { [weak self] in self?.objectWillChange.send() }
        workspace.sessions.append(session)
        workspace.selectedSessionID = session.id
    }

    /// A tab that runs `line` in the session's checkout (quorum, a check):
    /// in front, and started even while another session holds the stage.
    @discardableResult
    func runInNewTab(_ line: String, in workspace: Workspace) -> TerminalSession {
        let session = TerminalSession(
            directory: workspace.context.checkout ?? workspace.directory,
            command: Launcher.shellCommand(running: line)
        )
        add(session, to: workspace)
        BackgroundStart.start(session)
        return session
    }

    /// Visual order across all windows.
    var orderedWorkspaces: [Workspace] {
        windows.flatMap(\.orderedWorkspaces)
    }

    func select(_ workspace: Workspace, session: TerminalSession? = nil) {
        guard let window = window(of: workspace) else { return }
        if let session { workspace.selectedSessionID = session.id }
        window.select(workspace)
        if session != nil { window.showSection(.terminal) }
        if window !== activeWindow { window.bringToFront() }
    }

    func toggleInbox() {
        guard let window = activeWindow else { return }
        window.openLibrary("attention")
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

    func session(id: String) -> TerminalSession? {
        workspaces.lazy.flatMap(\.sessions).first { $0.id.uuidString == id }
    }

    func workspace(of session: TerminalSession) -> Workspace? {
        workspaces.first { $0.sessions.contains { $0.id == session.id } }
    }

    // MARK: - Closing

    private func closeWorkspace(_ workspace: Workspace) {
        let context = workspace.context
        let window = window(of: workspace)
        let index = window?.orderedWorkspaces.firstIndex { $0.id == workspace.id } ?? 0
        workspace.sessions.forEach { $0.terminate() }
        workspaces.removeAll { $0.id == workspace.id }
        window?.repairSelection(near: index)
        updateBadge()
        cleanUp(after: context)
    }

    // MARK: - Worktree cleanup

    private var cleaning: Set<Workspace.ID> = []

    /// A session's PR got merged: once nothing runs in it and you aren't
    /// looking at it, it closes and its worktree goes (when nothing in it
    /// would be lost). Asked again on every PR poll until then.
    func pullRequestMerged(in workspace: Workspace) {
        let context = workspace.context
        guard !cleaning.contains(workspace.id), !workspace.isBusy,
              !workspace.sessions.contains(where: { $0.agent == .blocked || $0.agent == .working }),
              window(of: workspace)?.selectedWorkspaceID != workspace.id,
              let root = context.root, let checkout = context.checkout,
              Worktrees.isManaged(checkout, root: root), !sharesCheckout(workspace)
        else { return }
        cleaning.insert(workspace.id)
        let pr = context.pr
        Task.detached(priority: .utility) {
            let finished = Worktrees.isFinished(checkout, pullRequest: pr, root: root)
            await MainActor.run {
                self.cleaning.remove(workspace.id)
                guard finished, self.workspaces.contains(where: { $0.id == workspace.id }),
                      !workspace.isBusy, self.window(of: workspace)?.selectedWorkspaceID != workspace.id
                else { return }
                let window = self.window(of: workspace)
                self.closeWorkspace(workspace)
                window?.show(L("#%d merged: session closed, worktree removed", pr ?? 0))
            }
        }
    }

    /// A closed session's worktree goes too when it holds nothing: merged,
    /// or never touched (a session you tried and dropped). Otherwise it
    /// stays, to be opened again.
    private func cleanUp(after context: RepoContext) {
        guard let root = context.root, let checkout = context.checkout,
              Worktrees.isManaged(checkout, root: root),
              !workspaces.contains(where: { $0.context.checkout == checkout })
        else { return }
        let merged = context.prState == .merged ? context.pr : nil
        let branch = context.branch
        Task.detached(priority: .utility) {
            guard Worktrees.isFinished(checkout, pullRequest: merged, root: root) else { return }
            Worktrees.remove(checkout, branch: branch, root: root)
        }
    }

    /// A variant you didn't keep: it closes without asking and its worktree
    /// goes. Nothing is lost: its branch stays, and its files as they were
    /// (uncommitted work included) stay as a checkpoint under refs/muxy/turns.
    func discardVariant(_ workspace: Workspace) {
        let context = workspace.context
        let window = window(of: workspace)
        let index = window?.orderedWorkspaces.firstIndex { $0.id == workspace.id } ?? 0
        workspace.sessions.forEach { $0.terminate() }
        workspaces.removeAll { $0.id == workspace.id }
        window?.repairSelection(near: index)
        updateBadge()
        guard let root = context.root, let checkout = context.checkout, Worktrees.isManaged(checkout, root: root),
              !workspaces.contains(where: { $0.context.checkout == checkout }) else { return }
        Task.detached(priority: .utility) {
            Checkpoints.record(.after, label: "Discarded variant", in: checkout)
            Worktrees.remove(checkout, branch: nil, root: root)
        }
    }

    /// Another open session works in the same checkout.
    private func sharesCheckout(_ workspace: Workspace) -> Bool {
        workspaces.contains { $0 !== workspace && $0.context.checkout == workspace.context.checkout }
    }

    /// One tab's program for another, in the same place, without asking:
    /// a planning agent that goes on with its permissions skipped.
    func replace(_ old: TerminalSession, with new: TerminalSession, in workspace: Workspace) {
        guard let index = workspace.sessions.firstIndex(where: { $0 === old }) else { return }
        new.onAttentionChange = { [weak self] in self?.updateBadge() }
        new.onContextChange = { [weak self] in self?.objectWillChange.send() }
        let selected = workspace.selectedSessionID == old.id
        old.terminate()
        // The old program's last writes (a conversation file) come first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let index = workspace.sessions.firstIndex(where: { $0 === old }) else { return }
            workspace.sessions[index] = new
            if selected { workspace.selectedSessionID = new.id }
            if self.window(of: workspace)?.selectedWorkspaceID != workspace.id { BackgroundStart.start(new) }
            self.sessionsChanged()
        }
        _ = index
    }

    func close(_ session: TerminalSession, in workspace: Workspace) {
        if workspace.sessions.count <= 1 {
            requestCloseWorkspace(workspace)
            return
        }
        confirm(
            running: session.needsCloseConfirmation,
            title: L("Close %@?", session.tabTitle),
            detail: L("The running process in %@ will end.", Paths.abbreviate(session.cwd))
        ) {
            session.terminate()
            self.detach(session, from: workspace)
            self.updateBadge()
        }
    }

    func requestCloseWorkspace(_ workspace: Workspace) {
        confirm(
            running: workspace.sessions.contains { $0.needsCloseConfirmation },
            title: L("Close %@?", workspace.title),
            detail: L("All tabs in %@ will end.", Paths.abbreviate(workspace.directory))
        ) {
            self.closeWorkspace(workspace)
        }
    }

    /// ⌘Q — one keystroke must never silently kill every agent.
    /// Always asks while any session is open — every agent ends with it.
    func shouldQuit() -> Bool {
        // Nothing ends when every tab runs under muxyd: quit as is.
        guard !workspaces.isEmpty, !workspaces.flatMap(\.sessions).allSatisfy(\.kept) else {
            saveSessions()
            return true
        }
        let running = workspaces.flatMap(\.sessions).filter(\.needsCloseConfirmation)
        let alert = NSAlert()
        alert.messageText = L("Quit muxy?")
        alert.informativeText = switch running.count {
        case 0: workspaces.count == 1
            ? L("The open session will end.")
            : L("All %d open sessions will end.", workspaces.count)
        case 1: L("Something is still running in one tab.")
        default: L("Something is still running in %d tabs.", running.count)
        }
        if restoreOnLaunch {
            alert.informativeText += " " + L("They come back when muxy opens again.")
        }
        alert.addButton(withTitle: L("Quit"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        saveSessions()
        return true
    }

    private func confirm(running: Bool, title: String, detail: String, then action: @escaping () -> Void) {
        guard running else {
            action()
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L("Close"))
        alert.addButton(withTitle: L("Cancel"))
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

    /// Where a dragged session would land.
    enum DropTarget {
        /// Nowhere new (its own sidebar).
        case stay
        /// Into another window's sidebar.
        case window(WindowModel)
        /// A new window with this frame.
        case newWindow(NSRect)
    }

    func dropTarget(for workspace: Workspace, at point: NSPoint) -> DropTarget {
        guard let source = window(of: workspace) else { return .stay }
        if let target = windowUnder(point), isOverSidebar(point, in: target) {
            return target === source ? .stay : .window(target)
        }
        let size = source.nsWindow?.frame.size ?? NSSize(width: 1280, height: 820)
        return .newWindow(Self.frame(size: size, grabbedAt: point))
    }

    /// A dragged sidebar row was dropped: on another window's sidebar it
    /// moves there; anywhere else it opens as its own window right there.
    func drop(_ workspace: Workspace, at point: NSPoint) {
        guard let source = window(of: workspace) else { return }
        switch dropTarget(for: workspace, at: point) {
        case .stay:
            return
        case let .window(target):
            move(workspace, from: source, to: target)
            target.bringToFront()
        case let .newWindow(frame):
            // The only session of a window: the window itself goes there.
            if source.workspaces.count == 1, let nsWindow = source.nsWindow {
                nsWindow.setFrame(frame, display: true, animate: false)
                source.bringToFront()
                return
            }
            let target = makeWindow()
            target.pendingFrame = frame
            move(workspace, from: source, to: target)
            openWindow?(id: "main", value: target.id)
        }
    }

    private func move(_ workspace: Workspace, from source: WindowModel, to target: WindowModel) {
        let index = source.orderedWorkspaces.firstIndex { $0.id == workspace.id } ?? 0
        workspace.windowID = target.id
        // Re-append so it lands at the end of the target's list.
        workspaces.removeAll { $0.id == workspace.id }
        workspaces.append(workspace)
        target.select(workspace)
        closeIfEmpty(source, near: index)
    }

    /// A window of `size` whose top-left sits where the drag preview was,
    /// kept on the screen under the pointer.
    static func frame(size: NSSize, grabbedAt point: NSPoint) -> NSRect {
        let topLeft = NSPoint(x: point.x - DragGhost.grabOffset.width, y: point.y + DragGhost.grabOffset.height)
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
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

    /// Agent hook (Claude Code and Codex): `start` (a conversation began
    /// or was resumed: its id), `prompt` (started working), `tool` (working,
    /// also when it resumes on its own), `notify` (needs you), `idle`
    /// (waiting for input: ends a turn that was interrupted), `error` (turn
    /// died on an API error), `stop` (turn finished). False when the
    /// session isn't ours.
    @discardableResult
    func handleHookEvent(_ event: HookWatcher.Event) -> Bool {
        for workspace in workspaces {
            guard let session = workspace.sessions.first(where: { $0.id.uuidString == event.session })
            else { continue }
            let kind = AgentKind(rawValue: event.agent) ?? session.kind
            session.kind = kind
            session.reportsByHook = true
            if let id = event.agentSession { session.agentSessionID = id }
            // The remote shows it as a chat; results read it too.
            if let transcript = event.transcript {
                session.transcriptPath = transcript
                Results.shared.noteLog(transcript, for: session)
            }
            switch event.name {
            case "start":
                if session.agent == .none { session.agent = .idle }
            case "prompt":
                // What the turn starts from, for its diff and to go back to.
                if session.agent != .working { Turns.shared.turnStarted(in: session) }
                session.agent = .working
            case "tool":
                session.agent = .working
            case "notify":
                session.agent = .blocked
                session.markAttentionIfBackground(reason: L("needs you"))
            case "idle":
                // Esc fires no Stop: this is the first word after it. A
                // pending permission prompt stays what it is.
                if session.agent == .working {
                    session.agent = .idle
                    Landing.shared.turnEnded(in: workspace)
                }
            case "error":
                session.agent = .failed
                session.markAttentionIfBackground(reason: L("hit an error"))
            default:
                session.agent = .idle
                session.turnsEnded += 1
                session.markAttentionIfBackground(reason: session.planning ? L("has a plan for you") : L("is done"))
                Results.shared.turnEnded(in: session)
                Landing.shared.turnEnded(in: workspace)
                // A turn often ends with a push: don't wait for the poll.
                if let primary = workspace.primary, Git.mayHavePR(primary.context.branch) {
                    primary.refreshContext()
                }
            }
            sessionsChanged()
            return true
        }
        return false
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
            // Only muxy's own windows: Settings & co. keep their keys.
            guard let self, event.window?.attachedSheet == nil,
                  event.window == nil || self.window(for: event.window) != nil
            else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private enum KeyCode {
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let digit = Int(key).flatMap { (1 ... 9).contains($0) ? $0 : nil }
        let window = self.window(for: event.window) ?? activeWindow

        switch (mods, event.keyCode) {
        case ([.command, .shift], KeyCode.returnKey): window?.toggleTerminalFocus(); return true
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
        if mods == [.command, .option], key == "n" {
            newShellInFront()
            return true
        }
        if mods == [.command, .shift] {
            switch key {
            case "n": newWindow()
            case "j": toggleInbox()
            case "d": window?.toggleReview()
            // Without a search open, ⇧⌘G stays the terminal's.
            case "g":
                guard let search = window?.selectedWorkspace?.selectedSession?.search else { return false }
                search.previous()
            default: return false
            }
            return true
        }
        guard mods == .command else { return false }
        // The ⌘N panel picks repositories with ⌘1…6.
        if window?.showNewSession == true, digit != nil { return false }
        if let digit {
            window?.selectTab(index: digit - 1)
            return true
        }
        switch key {
        case "h": targetWindow().goHome()
        case "n":
            let target = targetWindow()
            if target.showNewSession { target.showNewSession = false } else { target.newTask() }
        case "t": targetWindow().newTab()
        case "w": window?.closeCurrent()
        case "i": if let window { Results.shared.togglePanel(in: window) }
        case "k": window?.showSwitcher.toggle()
        case "b": toggleSidebar()
        case "f":
            guard window?.showNewSession != true, window?.showSwitcher != true,
                  let session = window?.selectedWorkspace?.selectedSession,
                  session.terminalView.currentSurface != nil else { return false }
            session.startSearch()
        case "g":
            guard let search = window?.selectedWorkspace?.selectedSession?.search else { return false }
            search.next()
        // Ghostty binds ⌘, to its own config — muxy's Settings win.
        case ",": openSettings?()
        // Ghostty binds ⌘Q to its own quit, which never reaches AppKit.
        case "q": NSApplication.shared.terminate(nil)
        default: return false
        }
        return true
    }

    // MARK: - Launching

    /// "New Session": a worktree if asked for, then a tab there whose shell
    /// starts the agent with the prompt. Calls back with an error message,
    /// or nil once the session is open.
    /// A new session from the ⌘N panel. Its card and tab appear at once;
    /// a worktree is made meanwhile and the agent starts in it as soon as
    /// it exists, as the tab's own program (nothing typed into a shell).
    func launch(_ spec: SessionSpec, in window: WindowModel) {
        let prompt = spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude takes the conversation id from us: resumable from the start.
        let conversation = spec.agent == .claude ? UUID().uuidString.lowercased() : nil
        let skipPermissions = spec.skipPermissions ?? skipPermissions
        let session = TerminalSession(
            directory: spec.directory,
            command: spec.agent.map {
                Launcher.shellCommand(running: $0.command(
                    .new(prompt: !prompt.isEmpty, id: conversation), skipPermissions: skipPermissions, plan: spec.plan
                ))
            },
            environment: prompt.isEmpty ? [:] : ["MUXY_PROMPT": prompt],
            preparing: spec.branch == nil ? nil : L("Creating worktree …")
        )
        session.kind = spec.agent
        session.agentSessionID = conversation
        session.skipsPermissions = spec.agent != nil && skipPermissions
        session.issue = spec.issue
        session.variantGroup = spec.variantGroup
        session.planning = spec.plan && spec.agent != nil
        if spec.agent != nil { session.agent = .idle }
        let workspace = makeWorkspace(directory: spec.directory, in: window, session: session)
        if spec.background {
            BackgroundStart.start(session)
        } else {
            window.select(workspace)
            window.bringToFront()
        }
        guard let branch = spec.branch else { return }

        #if DEBUG
        let began = Date()
        #endif
        Task.detached(priority: .userInitiated) {
            let result: Result<(path: String, problem: String?), Error>
            do {
                result = try .success(await Launcher.makeWorktree(from: spec.directory, branch: branch) { step in
                    Task { @MainActor in session.updatePreparing(step) }
                })
            } catch {
                result = .failure(error)
            }
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["MUXY_DEBUG_TIMING"],
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(String(format: "worktree ready after %.2fs\n", Date().timeIntervalSince(began)).utf8))
            }
            #endif
            await MainActor.run {
                switch result {
                case let .success(made):
                    session.begin(in: made.path)
                    // Another session took the stage meanwhile: start anyway.
                    BackgroundStart.start(session)
                    if let problem = made.problem {
                        session.markAttentionIfBackground(reason: problem)
                        self.window(of: workspace)?.show(problem)
                    }
                    if spec.autoName, !prompt.isEmpty {
                        self.nameBranch(of: session, placeholder: branch, task: prompt, agent: spec.agent)
                    }
                    self.sessionsChanged()
                case let .failure(error):
                    session.agent = .none
                    session.failPreparing((error as? Launcher.Failure)?.message ?? error.localizedDescription)
                }
            }
        }
    }

    /// The session already runs on its placeholder branch; the real name
    /// follows a few seconds later.
    private func nameBranch(of session: TerminalSession, placeholder: String, task: String, agent: AgentKind?) {
        let directory = session.cwd
        // Variants of one task keep their agent in the name, side by side.
        let suffix = session.variantGroup != nil ? agent.map { "-" + $0.rawValue } ?? "" : ""
        Task.detached(priority: .utility) {
            let wanted = BranchNamer.suggest(for: task, agent: agent, in: directory).map { $0 + suffix }
            let renamed = wanted.flatMap { BranchNamer.rename(in: directory, from: placeholder, to: $0) }
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["MUXY_DEBUG_TIMING"],
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data("named \(directory): \(wanted ?? "nil") → \(renamed ?? "nil")\n".utf8))
            }
            #endif
            guard renamed != nil else { return }
            await MainActor.run { session.refreshContext() }
        }
    }

    // MARK: - Menu commands

    func newWorkspaceInFront() { targetWindow().newTask() }
    func newTabInFront() { targetWindow().newTab() }
    /// ⌥⌘N: no questions, a shell in home, like any terminal's ⌘N.
    func newShellInFront() {
        let window = targetWindow()
        window.showNewSession = false
        window.newWorkspace()
    }

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
