import SwiftUI

/// Sessions grouped by repository: soft rounded rows, a filled row for the
/// active one, state carried by the tint of each row's tile and its PR
/// badge.
struct SidebarView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(window.groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.9)
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.textFaint)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(height: 24, alignment: .center)
                            ForEach(group.workspaces) { workspace in
                                SessionRow(store: store, window: window, workspace: workspace)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 46)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(width: store.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.surface.opacity(0.93))
    }

    private var footer: some View {
        FooterButton {
            window.newWorkspace()
        }
        .padding(10)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}

private struct FooterButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28)
                Text("Neue Session")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Kbd("⌘N")
            }
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textMuted)
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovered ? Theme.fillHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

private struct SessionRow: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    @State private var hovered = false

    private var isSelected: Bool { window.selectedWorkspaceID == workspace.id }

    var body: some View {
        HStack(spacing: 10) {
            SessionTile(agent: workspace.agent, attention: workspace.needsAttention, isGit: workspace.context.repo != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textBody)
                    .lineLimit(1)
                Text(workspace.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovered {
                Button {
                    store.requestCloseWorkspace(workspace)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.fillActive))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                PRBadge(pr: workspace.context.pr, status: workspace.prStatus)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.fillActive : (hovered ? Theme.fillHover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { window.select(workspace) }
        .gesture(
            // Drag out of the window → own window; onto another → moves there.
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { _ in DragGhost.update(title: workspace.title, from: window.nsWindow) }
                .onEnded { _ in
                    DragGhost.hide()
                    store.drop(workspace, at: NSEvent.mouseLocation)
                }
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .contextMenu {
            Button("Schließen") { store.requestCloseWorkspace(workspace) }
        }
        .help(Paths.abbreviate(workspace.directory))
    }
}
