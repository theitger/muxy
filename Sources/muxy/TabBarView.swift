import SwiftUI

/// The strip above the terminal, painted in the terminal's own color so it
/// reads as part of it. Tabs are a segmented control; on the right a
/// soft pill appears when another session wants you.
struct TabBarView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    /// Inside the stage card: the title bar above carries the window's
    /// controls, so this strip is only the tabs.
    var onStage = false

    var body: some View {
        HStack(spacing: 8) {
            if !onStage {
                IconButton(symbol: "sidebar.left", help: L("Sidebar (⌘B)")) {
                    store.toggleSidebar()
                }
            }
            HStack(spacing: 2) {
                ForEach(workspace.sessions) { session in
                    SegmentTab(store: store, workspace: workspace, session: session)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
            )
            IconButton(symbol: "plus", help: L("New Tab (⌘T)")) {
                window.newTab()
            }
            Spacer(minLength: 8)
            AppButton(workspace: workspace)
            ResultButton(window: window, workspace: workspace)
            if !onStage {
                InboxPill(store: store, window: window)
            }
        }
        // Folded sidebar: leave room for the traffic lights.
        .padding(.leading, onStage ? 8 : 80)
        .padding(.trailing, 12)
        .frame(height: onStage ? 42 : StageMetrics.topBar)
        // Matches the terminal and reaches 1pt under it: Ghostty leaves its
        // outermost pixels unpainted, which shows as a seam wherever the
        // window blur is missing (Mission Control).
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: onStage ? StageMetrics.radius : 0,
                topTrailingRadius: onStage ? StageMetrics.radius : 0,
                style: .continuous
            )
            .fill(Theme.terminal)
        )
    }
}

private struct SegmentTab: View {
    @ObservedObject var store: Store
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: TerminalSession
    @State private var hovered = false

    private var isActive: Bool { workspace.selectedSessionID == session.id }


    var body: some View {
        HStack(spacing: 6) {
            if let kind = session.kind, session.agent != .none {
                AgentGlyph(kind: kind, size: 11)
            }
            Text(session.tabTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.textPrimary : (hovered ? Theme.textBody : Theme.textMuted))
                .lineLimit(1)
            if session.needsAttention {
                Circle().fill(Theme.orange.strong).frame(width: 5, height: 5)
            } else if hovered, workspace.sessions.count > 1 {
                Button {
                    store.close(session, in: workspace)
                } label: {
                    Icon("xmark", size: 7.5)
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Theme.bg : .clear)
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 1.5, y: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedSessionID = session.id }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}
