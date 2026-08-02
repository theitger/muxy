import SwiftUI

/// Chrome-style tab strip: only the ACTIVE workspace's tabs, left-aligned
/// in the terminal column (the traffic lights live over the sidebar, so no
/// spacer needed here).
struct TabBarView: View {
    @ObservedObject var store: Store
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(workspace.sessions) { session in
                ChromeTab(store: store, workspace: workspace, session: session)
            }
            newTabButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Theme.surface.opacity(0.93))
    }

    private var newTabButton: some View {
        Button {
            store.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Neuer Tab (⌘T)")
    }
}

private struct ChromeTab: View {
    @ObservedObject var store: Store
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: TerminalSession
    @State private var hovered = false

    private var isActive: Bool { workspace.selectedSessionID == session.id }
    private var isExited: Bool {
        if case .exited = session.status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            if session.needsAttention {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
            }
            Text(session.title)
                .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .frame(minWidth: 100, maxWidth: 180)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedSessionID = session.id }
        .onHover { hovered = $0 }
    }

    private var titleColor: Color {
        if isExited { return Theme.textFaint }
        if isActive { return Theme.textPrimary }
        return Theme.textMuted
    }

    @ViewBuilder
    private var closeButton: some View {
        if isActive || hovered {
            Button {
                store.close(session, in: workspace)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
    }

    private var background: some ShapeStyle {
        if isActive { return AnyShapeStyle(Theme.surfaceActive) }
        if hovered { return AnyShapeStyle(Theme.surfaceActive.opacity(0.45)) }
        return AnyShapeStyle(.clear)
    }
}
