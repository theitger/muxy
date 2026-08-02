import SwiftUI

/// cmux semantics: the sidebar lists OPEN workspaces only. Closing one
/// removes its row. New ones come from ⌘N or the "+" menu (projects,
/// worktrees, plain terminal).
struct SidebarView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.workspaces) { workspace in
                        WorkspaceRow(store: store, workspace: workspace)
                    }
                    if store.workspaces.isEmpty {
                        emptyHint
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 44)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(Theme.surface.opacity(0.93))
    }

    private var emptyHint: some View {
        Text("Nichts offen.\n⌘N oder + unten für ein\nneues Terminal.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textFaint)
            .padding(12)
    }

}

/// Live terminal title (set by the shell via OSC, like a Ghostty window title).
private struct SessionTitleText: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool

    var body: some View {
        Text(session.title)
            .font(.system(size: 14, weight: isSelected ? .medium : .regular))
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textBody)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var store: Store
    @ObservedObject var workspace: Workspace
    @State private var hovered = false

    private var isSelected: Bool { store.selectedWorkspaceID == workspace.id }

    var body: some View {
        Button {
            store.selectedWorkspaceID = workspace.id
        } label: {
            HStack(spacing: 10) {
                if workspace.anyAttention {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                }
                if workspace.worktree == nil, let session = workspace.selectedSession {
                    SessionTitleText(session: session, isSelected: isSelected)
                } else {
                    Text(workspace.name)
                        .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textBody)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if workspace.sessions.count > 1 {
                    Text("\(workspace.sessions.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textFaint)
                }
                if hovered {
                    Button {
                        store.requestCloseWorkspace(workspace)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Schließen") { store.requestCloseWorkspace(workspace) }
        }
        .help(workspace.displayPath)
    }

    private var rowBackground: some ShapeStyle {
        if isSelected { return AnyShapeStyle(Theme.surfaceActive) }
        if hovered { return AnyShapeStyle(Theme.surfaceActive.opacity(0.55)) }
        return AnyShapeStyle(.clear)
    }
}
