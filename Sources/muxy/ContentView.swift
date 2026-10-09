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

    var body: some View {
        Group {
            if let model = store.window(windowID) {
                ContentView(store: store, window: model)
                    .id(language)
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
                if model.workspaces.isEmpty {
                    model.newWorkspace()
                    model.workspaces.first?.isLaunchDefault = true
                }
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
        Group {
            if store.sidebarVisible {
                stage
            } else {
                // Wings away: the terminal fills the window, like Ghostty.
                VStack(spacing: 0) {
                    if let workspace = window.selectedWorkspace {
                        TabBarView(store: store, window: window, workspace: workspace)
                        WorkspaceContent(workspace: workspace)
                    } else {
                        EmptyState()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if window.showSwitcher {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.32)
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
                    Color.black.opacity(0.32)
                        .contentShape(Rectangle())
                        .onTapGesture { window.showNewSession = false }
                    NewSessionView(store: store, window: window)
                        .padding(.top, 90)
                        .transition(.scale(scale: 0.97, anchor: .top).combined(with: .offset(y: 8)))
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
                        Capsule().fill(Theme.surface)
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    )
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(Theme.ease, value: window.toast)
        .animation(Theme.ease, value: window.showSwitcher)
        .animation(Theme.ease, value: window.showNewSession)
        .animation(.easeOut(duration: 0.2), value: window.attentionWorkspaces.map(\.id))
        .background(WindowConfigurator(model: window))
        .ignoresSafeArea()
    }

    /// Wings out: a title bar across, the wings, the session in front as a card.
    private var stage: some View {
        StageLayout(wingsWidth: store.sidebarWidth) {
            StageTopBar(store: store, window: window)
        } wings: {
            WingsView(store: store, window: window)
                .overlay(alignment: .trailing) { SidebarHandle(store: store) }
        } stage: {
            VStack(spacing: 0) {
                if let workspace = window.selectedWorkspace {
                    TabBarView(store: store, window: window, workspace: workspace, onStage: true)
                    WorkspaceContent(workspace: workspace, cornerRadius: StageMetrics.radius)
                        // What a session fades in over when it takes the stage.
                        .background(
                            UnevenRoundedRectangle(
                                bottomLeadingRadius: StageMetrics.radius,
                                bottomTrailingRadius: StageMetrics.radius, style: .continuous
                            )
                            .fill(Theme.terminal)
                        )
                } else {
                    EmptyState()
                        .clipShape(RoundedRectangle(cornerRadius: StageMetrics.radius, style: .continuous))
                }
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
        HStack(spacing: 4) {
            // The traffic lights.
            Color.clear.frame(width: 72)
            IconButton(symbol: "sidebar.left", help: L("Sidebar (⌘B)")) {
                store.toggleSidebar()
            }
            IconButton(
                symbol: store.detailedWings ? "rectangle.grid.1x2" : "list.bullet",
                help: store.detailedWings ? L("Simple Sessions") : L("Detailed Sessions")
            ) {
                store.toggleDetailedWings()
            }
            Spacer(minLength: 12)
            if let workspace = window.selectedWorkspace {
                StageTitle(
                    title: workspace.title,
                    place: [workspace.context.repo, workspace.subtitle].compactMap { $0 }.joined(separator: " · "),
                    pr: workspace.context.pr,
                    prStatus: workspace.prStatus
                )
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                AttentionPill(store: store, window: window)
                TitleBarButton(symbol: "plus", title: L("New Session"), keys: "⌘N") {
                    window.showNewSession = true
                }
            }
        }
        .padding(.trailing, 10)
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
private struct WorkspaceContent: View {
    @ObservedObject var workspace: Workspace
    var cornerRadius: CGFloat = 0

    var body: some View {
        if let session = workspace.selectedSession {
            TerminalHostView(session: session, cornerRadius: cornerRadius)
                .id(session.id)
                .overlay { Preparing(session: session, cornerRadius: cornerRadius) }
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

/// Nothing open: a calm serif headline and the few keys that matter.
private struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("What are you working on?"))
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text(L("Every session is a folder with its tabs."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
            }
            VStack(spacing: 0) {
                hint(L("New Session"), "⌘N")
                divider
                hint(L("Search sessions"), "⌘K")
                divider
                hint(L("Next one waiting"), "⌘J")
                divider
                hint(L("New Window"), "⇧⌘N")
            }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .frame(width: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminal)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline.opacity(0.7)).frame(height: 1)
    }

    private func hint(_ label: String, _ keys: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textBody)
            Spacer()
            Kbd(keys)
        }
        .frame(height: 40)
    }
}
