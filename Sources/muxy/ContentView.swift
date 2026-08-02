import SwiftUI

struct ContentView: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store)
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
            VStack(spacing: 0) {
                if let workspace = store.selectedWorkspace {
                    TabBarView(store: store, workspace: workspace)
                    WorkspaceContent(workspace: workspace)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .onAppear {
            store.loadProjects()
            store.installKeyMonitor()
            store.startHookWatcher()
        }
        .sheet(isPresented: $store.showNewWorktreeSheet) {
            NewWorktreeSheet(store: store)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Kein Terminal offen")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textDim)
            Text("Worktree anklicken oder ⌘N für ein neues Terminal")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textFaint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.93))
    }
}

/// Path header + the active tab's terminal for one workspace.
private struct WorkspaceContent: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            if let session = workspace.selectedSession {
                TerminalHostView(session: session)
                    .id(session.id)
            } else {
                Theme.surface.opacity(0.93)
            }
        }
    }
}
