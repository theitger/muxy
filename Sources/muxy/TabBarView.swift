import SwiftUI

/// The strip above the terminal, painted in the terminal's own color so it
/// reads as part of it. Tabs are a segmented control; on the right a
/// soft pill appears when another session wants you.
struct TabBarView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "sidebar.left", help: "Seitenleiste (⌘B)") {
                store.toggleSidebar()
            }
            HStack(spacing: 2) {
                ForEach(workspace.sessions) { session in
                    SegmentTab(store: store, window: window, workspace: workspace, session: session)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
            )
            IconButton(symbol: "plus", help: "Neuer Tab (⌘T)") {
                window.newTab()
            }
            Spacer(minLength: 8)
            AttentionPill(store: store, window: window)
        }
        // Folded sidebar: leave room for the traffic lights.
        .padding(.leading, store.sidebarVisible ? 10 : 80)
        .padding(.trailing, 12)
        .frame(height: 46)
        // The terminal paints its own background; this strip matches it.
        .background(Theme.terminal)
    }
}

private struct SegmentTab: View {
    @ObservedObject var store: Store
    let window: WindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: TerminalSession
    @State private var hovered = false

    private var isActive: Bool { workspace.selectedSessionID == session.id }

    private var symbol: String {
        if session.agent != .none { return "sparkle" }
        return "chevron.forward"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Theme.textMuted : Theme.textFaint)
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
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
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
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .fill(isActive ? Theme.bg : .clear)
                .shadow(color: .black.opacity(isActive ? 0.08 : 0), radius: 1.5, y: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectedSessionID = session.id }
        .gesture(
            // Drag out → own window; onto the sidebar or another window →
            // its own session there.
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { _ in DragGhost.update(title: session.tabTitle, from: window.nsWindow) }
                .onEnded { _ in
                    DragGhost.hide()
                    store.drop(session, from: workspace, at: NSEvent.mouseLocation)
                }
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textDim)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovered ? Theme.fillHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
    }
}

/// "2027-scrollbar wartet ⌘J" — visible from any session, so the sidebar
/// can stay hidden without missing anything.
private struct AttentionPill: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel

    var body: some View {
        let waiting = window.attentionWorkspaces
        if let first = waiting.first {
            Button {
                store.jumpToAttention()
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(Theme.orange.strong).frame(width: 6, height: 6)
                    Text(waiting.count == 1 ? first.title : "\(waiting.count) Sessions warten")
                        .lineLimit(1)
                        .frame(maxWidth: 220)
                    Text("⌘J").opacity(0.55)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.orange.strong)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(Theme.orange.soft))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}
