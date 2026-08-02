import SwiftUI

/// ⌘N: pick a project, name a branch, get a worktree with an open terminal.
struct NewWorktreeSheet: View {
    @ObservedObject var store: Store
    @State private var projectPath: String = ""
    @State private var branch: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Neuer Worktree")
                .font(.system(size: 15, weight: .semibold))
            Picker("Projekt", selection: $projectPath) {
                ForEach(store.projects) { project in
                    Text(project.name).tag(project.path)
                }
            }
            TextField("Branch-Name", text: $branch)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { store.showNewWorktreeSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Erstellen", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(branch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if projectPath.isEmpty {
                projectPath = store.projects.first?.path ?? ""
            }
        }
    }

    private func create() {
        guard let project = store.projects.first(where: { $0.path == projectPath }) else { return }
        errorText = nil
        store.createWorktree(project: project, branch: branch) { message in
            errorText = message
        }
    }
}
