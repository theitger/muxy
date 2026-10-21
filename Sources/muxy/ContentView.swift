import SwiftUI

/// Resolves which window model a scene shows. A plain new window (launch,
/// Dock click) adopts a model nobody has shown yet or makes one.
struct WindowRoot: View {
    @Binding var windowID: WindowModel.ID?
    @ObservedObject private var store = Store.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Rebuilds the window when the language changes (terminals survive:
    /// they are only reparented).
    @AppStorage(Language.storageKey) private var language = Language.english.rawValue
    @ObservedObject private var appearance = AppearanceWatch.shared

    var body: some View {
        Group {
            if let model = store.window(windowID) {
                ContentView(store: store, window: model)
                    .id("\(language)-\(appearance.isDark)")
            } else {
                Color.clear
            }
        }
        // Folders opened from outside (`open -a Muxy dir`) go to an existing
        // window instead of spawning a new one per folder.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
            guard let model = store.window(windowID) else { return }
            store.openDirectory(url, in: model)
        }
        .onAppear {
            store.openWindow = openWindow
            store.openSettings = openSettings
            store.start()
            if store.window(windowID) == nil {
                let model = store.windows.first { !$0.claimed } ?? store.makeWindow()
                model.claimed = true
                windowID = model.id
                if model.workspaces.isEmpty {
                    store.restoreSessions(into: model)
                }
                model.goHome()
            } else {
                store.window(windowID)?.claimed = true
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            StageTopBar(store: store, window: window)
                .frame(height: StageMetrics.topBar)
                .background(Theme.sidebar)
            HStack(spacing: 0) {
                if store.sidebarVisible && !window.isTerminalFocused {
                    WingsView(store: store, window: window)
                        .frame(width: store.sidebarWidth)
                        .overlay(alignment: .trailing) { SidebarHandle(store: store) }
                }
                destination
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            }
            if !window.isTerminalFocused { StatusBar(store: store, window: window) }
        }
        .overlay(alignment: .top) {
            if window.showSwitcher {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { window.showSwitcher = false }
                    SwitcherView(store: store, window: window)
                        .padding(.top, 90)
                        .transition(.scale(scale: 0.97, anchor: .top).combined(with: .offset(y: 8)))
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if window.showNewSession {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { window.showNewSession = false }
                    ScrollView {
                        NewSessionView(store: store, window: window)
                            .background(DialogOutsideClick { window.showNewSession = false })
                            .padding(.vertical, 32)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.never)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = window.toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(Theme.ease, value: window.toast)
        .animation(Theme.ease, value: window.showSwitcher)
        .animation(Theme.ease, value: window.showNewSession)
        .animation(Theme.ease, value: window.showHub)
        .animation(.easeOut(duration: 0.2), value: window.attentionWorkspaces.map(\.id))
        .background(WindowConfigurator(model: window))
        // Controls in ink, not the system accent: color means state here.
        .tint(Theme.textPrimary)
        .ignoresSafeArea()
    }

    @ViewBuilder private var destination: some View {
        switch window.destination {
        case .home:
            HomeView(store: store, window: window)
        case .library:
            HubView(store: store, window: window)
        case .workspace:
            if let workspace = window.selectedWorkspace {
                WorkbenchView(store: store, window: window, workspace: workspace)
                    .id(workspace.id)
            } else {
                HomeView(store: store, window: window)
            }
        }
    }

}

/// Across the top with the wings out: the window's controls, what is on
/// stage, who else wants you, and a new session.
private struct StageTopBar: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 68)
            IconButton(symbol: "sidebar.left", help: L("Sidebar (⌘B)")) { store.toggleSidebar() }
            Button { window.goHome() } label: {
                HStack(spacing: 7) {
                    Text("muxy").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("/").foregroundStyle(Theme.textFaint)
                    Text(location).font(UI.control).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(Theme.textBody)
            }.buttonStyle(.plain)
            if window.destination == .workspace, let workspace = window.selectedWorkspace {
                if let branch = workspace.context.branch, branch != workspace.title {
                    Text(branch).font(UI.metadata).foregroundStyle(Theme.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                PRBadge(pr: workspace.context.pr, status: workspace.prStatus)
            }
            Spacer(minLength: 8)
            if window.isTerminalFocused {
                ActionButton(title: L("Exit terminal focus"), symbol: "arrow.down.right.and.arrow.up.left") {
                    window.toggleTerminalFocus()
                }
            }
            IconButton(symbol: "magnifyingglass", help: L("Search sessions (⌘K)")) { window.showSwitcher = true }
            ActionButton(title: L("New session"), symbol: "plus") { window.newTask() }
        }
        .padding(.trailing, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var location: String {
        switch window.destination {
        case .home: return L("Start")
        case .workspace: return window.selectedWorkspace?.title ?? L("Terminal")
        case .library:
            if let target = window.taskTarget { return target.title }
            if window.reviewRun != nil { return L("Review") }
            switch window.libraryPage {
            case "queue": return L("Queue")
            case "attention": return L("Needs you")
            case "reviews": return L("Reviews")
            case "worktrees": return L("Worktrees")
            default: return L("Tasks")
            }
        }
    }

}

/// The sidebar's edge: a hairline with a wider invisible grip. Drag to
/// resize; drag far enough left and the sidebar folds away.
private struct SidebarHandle: View {
    @ObservedObject var store: Store
    @State private var startWidth: Double?
    @State private var hovered = false

    var body: some View {
        Rectangle()
            .fill(hovered || startWidth != nil ? Theme.textPrimary.opacity(0.2) : .clear)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovered = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? store.sidebarWidth
                                startWidth = start
                                let proposed = start + value.translation.width
                                if proposed < Store.sidebarWidthRange.lowerBound - 70 {
                                    startWidth = nil
                                    store.sidebarVisible = false
                                    return
                                }
                                // Whole points only: fractional edges blur and seam.
                                store.sidebarWidth = min(max(proposed, Store.sidebarWidthRange.lowerBound),
                                                         Store.sidebarWidthRange.upperBound).rounded()
                            }
                            .onEnded { _ in startWidth = nil }
                    )
                    .onTapGesture(count: 2) { store.sidebarWidth = 256 }
            }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// The active tab's terminal for one workspace.
/// The terminal, and the app's preview beside it while one is open.
struct WithPreview<Terminal: View>: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var previews = Previews.shared
    var cornerRadius: CGFloat
    @ViewBuilder var terminal: Terminal
    @State private var showingPreview = true

    private var terminalMinimum: CGFloat {
        guard let view = workspace.selectedSession?.terminalView,
              let columns = view.currentSurface?.gridSize.columns, columns > 0 else { return 800 }
        // Use the actual terminal grid, including the user's font/zoom.
        return max(800, ceil(view.bounds.width / CGFloat(columns) * 80) + 32)
    }

    var body: some View {
        GeometryReader { geometry in
            if previews.port(open: workspace) == nil {
                terminal
            } else if let width = WorkbenchLayout.previewWidth(available: geometry.size.width, terminalMinimum: terminalMinimum) {
                HStack(spacing: 0) {
                    terminal
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    PreviewPane(workspace: workspace).frame(width: width)
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Button(L("Terminal")) { showingPreview = false }
                            .font(UI.control).foregroundStyle(showingPreview ? Theme.textMuted : Theme.textPrimary)
                        Button(L("App preview")) { showingPreview = true }
                            .font(UI.control).foregroundStyle(showingPreview ? Theme.textPrimary : Theme.textMuted)
                        Spacer()
                    }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 36).background(Theme.sidebar)
                    if showingPreview { PreviewPane(workspace: workspace) }
                    else { terminal }
                }
            }
        }
        .onChange(of: previews.port(open: workspace)) { _, port in
            if port != nil { showingPreview = true }
        }
    }
}

struct WorkspaceContent: View {
    @ObservedObject var workspace: Workspace
    var cornerRadius: CGFloat = 0

    var body: some View {
        if let session = workspace.selectedSession {
            TerminalHostView(session: session, cornerRadius: cornerRadius)
                .id(session.id)
                .overlay { Preparing(session: session, cornerRadius: cornerRadius) }
                .overlay(alignment: .topTrailing) { SearchOverlay(session: session) }
        } else {
            Color.clear
        }
    }
}

/// A tab whose folder is still being made: the terminal's own background
/// and one quiet line, until the agent takes over.
private struct Preparing: View {
    @ObservedObject var session: TerminalSession
    var cornerRadius: CGFloat

    var body: some View {
        if let text = session.preparing {
            HStack(spacing: 8) {
                if session.agent != .none {
                    ProgressView().controlSize(.small)
                }
                Text(text)
                    .font(Theme.mono(size: 12.5))
                    .foregroundStyle(session.agent != .none ? Theme.textDim : Theme.redTone.strong)
                    .textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius, style: .continuous
                )
                .fill(Theme.terminal)
            )
            .transition(.opacity)
        }
    }
}
