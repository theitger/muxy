import SwiftUI

/// The wings: every session as a card beside the stage, grouped by
/// repository, in a stable order. The session on stage keeps its card,
/// framed, at its size and place, so nothing moves when you switch.
struct WingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject private var queue = Queue.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                navigation(L("Start"), symbol: "house", selected: window.destination == .home) { window.goHome() }
                navigation(L("Tasks"), symbol: "list.bullet", selected: library("board")) { window.openLibrary() }
                navigation(L("Queue") + (queue.items.isEmpty ? "" : " · \(queue.items.count)"), symbol: "list.bullet.rectangle", selected: library("queue")) { window.openLibrary("queue") }
                navigation(L("Needs you"), symbol: "hand.raised.fill", selected: library("attention")) { window.openLibrary("attention") }
            }.padding(12)
            Divider().padding(.horizontal, 16)
            HStack {
                Text(L("Sessions")).font(UI.metadata).foregroundStyle(Theme.textMuted)
                Spacer()
                IconButton(symbol: "plus", help: L("New session")) { window.newTask() }
            }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(window.groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(UI.metadata).foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 10).padding(.bottom, 4)
                            ForEach(group.workspaces) { workspace in
                                WingCard(store: store, window: window, workspace: workspace)
                            }
                        }
                    }
                    if window.workspaces.isEmpty {
                        Text(L("Your tasks and terminals appear here."))
                            .font(UI.metadata).foregroundStyle(Theme.textMuted)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(SessionScrollIndicator())
            }.scrollIndicators(.visible)
            Divider().padding(.horizontal, 16)
            VStack(spacing: 3) {
                navigation(L("Reviews"), symbol: "shield", selected: library("reviews")) { window.openLibrary("reviews") }
                navigation(L("Worktrees"), symbol: "arrow.triangle.branch", selected: library("worktrees")) { window.openLibrary("worktrees") }
                navigation(L("Settings"), symbol: "gearshape", selected: false) { store.openSettings?() }
            }.padding(12)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func library(_ page: String) -> Bool {
        window.destination == .library && window.taskTarget == nil && window.reviewRun == nil && window.libraryPage == page
    }

    private func navigation(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Icon(symbol, size: 16)
                Text(title).font(UI.control)
                Spacer()
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.fillActive : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

}

private struct WingCard: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject private var results = Results.shared
    @ObservedObject private var previews = Previews.shared
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var landing = Landing.shared
    @State private var hovered = false

    var body: some View {
        WingCardFace(
            face: workspace.face, detailed: false, hovered: hovered,
            onStage: window.destination == .workspace && window.selectedWorkspaceID == workspace.id,
            openDetails: workspace.context.repo == nil ? nil : { window.openTask(TaskTarget(workspace: workspace)) },
            close: { store.requestCloseWorkspace(workspace) }
        )
        .contentShape(Rectangle())
        .onTapGesture { window.openTerminal(workspace) }
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
            if workspace.context.checkout != nil {
                Button(L("Review Changes")) { window.openReview(workspace, scope: .branch) }
                if let root = workspace.context.root, let checkout = workspace.context.checkout {
                    Button(L("Run Checks")) { Proofs.shared.run(checkout: checkout, root: root, session: workspace.primary) }
                }
            }
            if Landing.shared.canLand(workspace) {
                Button(L("Land")) { Landing.shared.land(workspace) }
            }
            if workspace.context.pr != nil, Quorum.isInstalled {
                Button(L("Babysit with quorum")) { QuorumWatch.shared.start(.babysit, in: workspace) }
            }
            if workspace.variantGroup != nil {
                Button(L("Keep This Variant")) { FanOut.confirmKeep(workspace) }
            }
            Divider()
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
            agents: sessions.filter { $0.agent != .none }.map(\.agent),
            result: resultFace,
            appPort: Previews.shared.ports(of: self).first(where: \.isWeb)?.port,
            subtitle: subtitle,
            kind: featured?.kind,
            sessionStatus: sessionStatus
        )
    }
}
