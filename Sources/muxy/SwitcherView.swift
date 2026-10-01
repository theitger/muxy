import SwiftUI

/// ⌘K — a command palette over all sessions. Type a few letters of a
/// title, folder, branch or PR number, hit return.
struct SwitcherView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [Workspace] {
        let words = query.lowercased().split(separator: " ")
        let all = store.orderedWorkspaces
        guard !words.isEmpty else { return all }
        return all.filter { workspace in
            let haystack = workspace.searchText
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                TextField("Session suchen …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { open(results) }
                Kbd("esc")
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            if results.isEmpty {
                Text("Keine Session gefunden.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, workspace in
                            if index == 0 || results[index - 1].groupName != workspace.groupName {
                                Text(workspace.groupName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.textDim)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 4 : 10)
                                    .padding(.bottom, 4)
                            }
                            row(workspace, index: index)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 540)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.12), radius: 30, y: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func row(_ workspace: Workspace, index: Int) -> some View {
        HStack(spacing: 10) {
            SessionTile(
                agent: workspace.agent, attention: workspace.needsAttention,
                isGit: workspace.context.repo != nil, size: 24
            )
            Text(workspace.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(workspace.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            PRBadge(pr: workspace.context.pr, status: workspace.prStatus)
            if index < 9 {
                Text("⌃\(index + 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 22, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(index == highlighted ? Theme.fillActive : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.select(workspace)
            dismiss()
        }
        .onHover { if $0 { highlighted = index } }
    }

    private func open(_ results: [Workspace]) {
        guard results.indices.contains(highlighted) else { return }
        store.select(results[highlighted])
        dismiss()
    }

    private func dismiss() {
        window.showSwitcher = false
    }
}
