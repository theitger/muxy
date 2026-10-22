import SwiftUI

/// Terminal instances and their own status, independent of repository views.
struct TabBarView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(workspace.sessions) { session in
                        SegmentTab(store: store, workspace: workspace, session: session)
                    }
                }.padding(3)
            }.scrollIndicators(.never)
            if window.isTerminalFocused {
                SmallButton(title: "Quorum", symbol: "checkmark.shield") { window.showSection(.quorum) }
            }
            AppButton(workspace: workspace)
            IconButton(symbol: "plus", help: L("New Tab (⌘T)")) { window.newTab() }
            IconButton(symbol: window.isTerminalFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       help: L("Focus terminal (⇧⌘↩)")) { window.toggleTerminalFocus() }
            if workspace.context.repo == nil {
                Menu {
                    Button(L("Close session")) { store.requestCloseWorkspace(workspace) }
                } label: { Icon("ellipsis", size: 14).frame(width: 24, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.surface)
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
            if let status = session.tabStatus {
                SessionSummaryLine(status: status)
            }
            if hovered, workspace.sessions.count > 1 {
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
