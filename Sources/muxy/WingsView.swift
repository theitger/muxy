import SwiftUI

/// The wings: every session as a card beside the stage, grouped by
/// repository, in a stable order. The session on stage keeps its card,
/// framed, at its size and place, so nothing moves when you switch.
struct WingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(window.groups) { group in
                    VStack(alignment: .leading, spacing: store.detailedWings ? 9 : 2) {
                        Text(group.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.9)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 20, alignment: .center)
                        ForEach(group.workspaces) { workspace in
                            WingCard(store: store, window: window, workspace: workspace)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }
}

private struct WingCard: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    @State private var hovered = false

    var body: some View {
        WingCardFace(
            face: workspace.face, detailed: store.detailedWings, hovered: hovered,
            onStage: window.selectedWorkspaceID == workspace.id
        )
        .contentShape(Rectangle())
        .onTapGesture { window.select(workspace) }
        .gesture(
            // Drop anywhere → its own window right there; on another
            // window's wings → moves into that window.
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { _ in
                    DragGhost.update(workspace, target: store.dropTarget(for: workspace, at: NSEvent.mouseLocation))
                }
                .onEnded { _ in
                    DragGhost.hide()
                    store.drop(workspace, at: NSEvent.mouseLocation)
                }
        )
        .onHover { hovered = $0 }
        .animation(Theme.ease, value: hovered)
        // Taking the stage and leaving it ease like the hover does.
        .animation(Theme.ease, value: window.selectedWorkspaceID == workspace.id)
        .contextMenu {
            Button(L("Close")) { store.requestCloseWorkspace(workspace) }
        }
        .help(Paths.abbreviate(workspace.directory))
    }
}

extension Workspace {
    /// What its card shows.
    var face: WingFace {
        WingFace(
            title: title,
            agent: agent,
            attention: needsAttention,
            isGit: context.repo != nil,
            pr: context.pr,
            prStatus: prStatus,
            activity: activity,
            lines: featured?.snapshot?.lines ?? [],
            agents: sessions.filter { $0.agent != .none }.map(\.agent)
        )
    }
}
