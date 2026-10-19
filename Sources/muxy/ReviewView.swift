import SwiftUI

/// What a session's agent changed, file by file: in its last turn, on
/// the whole branch, or in any earlier turn. Comments on lines go to the
/// agent in one message. Opens over the stage (⇧⌘D).
@MainActor
final class ReviewModel: ObservableObject {
    enum Scope: Hashable {
        case lastTurn
        case branch
        /// One recorded turn: from the checkpoint before it to this one.
        case turn(Checkpoint)
    }

    let workspace: Workspace
    let checkout: String
    let root: String
    @Published var scope: Scope
    @Published private(set) var files: [FileDiff] = []
    @Published var selected: String?
    @Published private(set) var loading = false
    @Published private(set) var note: String?
    @Published var comments: [ReviewComment] = []
    /// The line a comment is being written for.
    @Published var drafting: (path: String, line: FileDiff.Line)?
    private var token = 0

    init?(workspace: Workspace, scope: Scope = .lastTurn) {
        guard let checkout = workspace.context.checkout, let root = workspace.context.root else { return nil }
        self.workspace = workspace
        self.checkout = checkout
        self.root = root
        self.scope = scope
    }

    var additions: Int { files.map(\.additions).reduce(0, +) }
    var deletions: Int { files.map(\.deletions).reduce(0, +) }
    var selectedFile: FileDiff? { files.first { $0.path == selected } ?? files.first }

    /// The tab the comments go to: the one running an agent.
    var agentSession: TerminalSession? {
        workspace.sessions.first { $0.kind != nil && $0.agent != .none } ?? workspace.featured
    }

    func load() {
        token += 1
        let token = token
        loading = true
        let scope = scope
        let checkout = checkout
        let root = root
        let checkpoints = Turns.shared.checkpoints(for: checkout)
        Task.detached(priority: .userInitiated) {
            let (files, note) = Self.diff(scope: scope, checkout: checkout, root: root, checkpoints: checkpoints)
            await MainActor.run {
                guard token == self.token else { return }
                self.loading = false
                self.files = files
                self.note = note
                if !files.contains(where: { $0.path == self.selected }) { self.selected = files.first?.path }
            }
        }
    }

    nonisolated static func diff(
        scope: Scope, checkout: String, root: String, checkpoints: [Checkpoint]
    ) -> ([FileDiff], String?) {
        switch scope {
        case .lastTurn:
            guard let before = checkpoints.first(where: { $0.moment == .before }) else {
                let (files, _) = diff(scope: .branch, checkout: checkout, root: root, checkpoints: checkpoints)
                return (files, L("No turn recorded yet: the whole branch instead."))
            }
            guard let now = WorkState.snapshot(of: checkout) else { return ([], nil) }
            return (Diffs.load(from: before.commit, to: now.commit, in: checkout), nil)
        case .branch:
            guard let now = WorkState.snapshot(of: checkout),
                  let base = WorkState.base(of: checkout, root: root) else { return ([], nil) }
            return (Diffs.load(from: base, to: now.commit, in: checkout), nil)
        case let .turn(checkpoint):
            // The checkpoint just older than this one.
            let older = checkpoints.drop { $0.ref != checkpoint.ref }.dropFirst().first
            let base = older?.commit ?? (checkpoint.commit + "^")
            return (Diffs.load(from: base, to: checkpoint.commit, in: checkout), nil)
        }
    }

    func addComment(_ text: String) {
        guard let drafting, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let line = drafting.line
        comments.append(ReviewComment(
            path: drafting.path, line: line.new ?? line.old ?? 0, removed: line.role == .removed,
            code: line.text, text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        self.drafting = nil
    }

    func send() -> Bool {
        guard !comments.isEmpty, let session = agentSession else { return false }
        RemoteState.type(ReviewMessage.compose(comments), enter: true, into: session)
        comments = []
        return true
    }
}

struct ReviewOverlay: View {
    @ObservedObject var window: WindowModel

    var body: some View {
        if let model = window.review {
            ReviewView(model: model) { window.closeReview() }
                .padding(10)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject private var turns = Turns.shared
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                fileList.frame(width: 230)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                diffPane
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onAppear {
            turns.refresh(model.checkout)
            model.load()
        }
        .onChange(of: model.scope) { model.load() }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("Changes"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Picker("", selection: $model.scope) {
                Text(L("Last turn")).tag(ReviewModel.Scope.lastTurn)
                Text(L("Whole branch")).tag(ReviewModel.Scope.branch)
                let afters = turns.checkpoints(for: model.checkout).filter { $0.moment == .after }
                if !afters.isEmpty {
                    Divider()
                    ForEach(afters.prefix(20)) { checkpoint in
                        Text(turnTitle(checkpoint)).tag(ReviewModel.Scope.turn(checkpoint))
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            if model.loading {
                ProgressView().controlSize(.small)
            } else {
                Text(model.files.isEmpty ? L("No changes") : L("%d files · +%d −%d", model.files.count, model.additions, model.deletions))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            if let note = model.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer()
            if !model.comments.isEmpty {
                Button {
                    if model.send() { close() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10.5, weight: .semibold))
                        Text(model.comments.count == 1 ? L("Send 1 comment to the agent") : L("Send %d comments to the agent", model.comments.count))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.textPrimary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.agentSession == nil)
            }
            IconButton(symbol: "arrow.clockwise", help: L("Reload"), action: model.load)
            IconButton(symbol: "xmark", help: L("Close (esc)"), action: close)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 46)
    }

    private func turnTitle(_ checkpoint: Checkpoint) -> String {
        let time = checkpoint.date.formatted(date: .omitted, time: .shortened)
        let label = checkpoint.label.isEmpty ? L("Turn") : checkpoint.label
        return "\(time) · " + (label.count > 60 ? String(label.prefix(59)) + "…" : label)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.files) { file in
                    FileRow(file: file, selected: model.selectedFile?.path == file.path,
                            comments: model.comments.filter { $0.path == file.path }.count) {
                        model.selected = file.path
                    }
                }
            }
            .padding(6)
        }
        .scrollIndicators(.never)
        .background(Theme.textPrimary.opacity(0.02))
    }

    @ViewBuilder
    private var diffPane: some View {
        if let file = model.selectedFile {
            FileDiffView(file: file, model: model)
                .id(file.path + "\(model.scope.hashValue)")
        } else {
            Text(model.loading ? L("Reading the changes …") : L("Nothing changed here."))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FileRow: View {
    let file: FileDiff
    let selected: Bool
    let comments: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tone)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textBody)
                        .lineLimit(1)
                    let folder = (file.path as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if comments > 0 {
                    Badge(text: "\(comments)", tone: Theme.blue, symbol: "text.bubble.fill")
                }
                Text("+" + String(file.additions)).foregroundStyle(Theme.greenTone.strong)
                Text("−" + String(file.deletions)).foregroundStyle(Theme.redTone.strong)
            }
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Theme.fillActive : (hovered ? Theme.fillHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(file.path)
    }

    private var symbol: String {
        switch file.kind {
        case .added: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .binary: "doc"
        case .modified: "circle.fill"
        }
    }

    private var tone: Color {
        switch file.kind {
        case .added: Theme.greenTone.strong
        case .deleted: Theme.redTone.strong
        default: Theme.textDim
        }
    }
}

private struct FileDiffView: View {
    let file: FileDiff
    @ObservedObject var model: ReviewModel
    /// Huge diffs (generated files, lockfiles) would stall the view.
    private static let limit = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .font(Theme.mono(size: 11.5))
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                Button(L("Open")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: (model.checkout as NSString).appendingPathComponent(file.path)))
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if file.kind == .binary {
                placeholder(L("A binary file: no lines to show."))
            } else if file.lines.count > Self.limit {
                placeholder(L("%d lines: too long to show here.", file.lines.count))
            } else {
                // Top-left, rows as wide as the pane at least: long lines scroll.
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(file.lines) { line in
                                DiffLineRow(line: line, path: file.path, model: model)
                                    .frame(minWidth: geometry.size.width, alignment: .leading)
                            }
                        }
                        .padding(.bottom, 20)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffLineRow: View {
    let line: FileDiff.Line
    let path: String
    @ObservedObject var model: ReviewModel
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            ForEach(model.comments.filter { $0.path == path && $0.code == line.text && $0.line == (line.new ?? line.old) }) { comment in
                CommentCard(text: comment.text) {
                    model.comments.removeAll { $0.id == comment.id }
                }
            }
            if let drafting = model.drafting, drafting.path == path, drafting.line == line {
                CommentEditor(onSave: model.addComment) { model.drafting = nil }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            ZStack {
                if hovered, line.role != .hunk {
                    Button {
                        model.drafting = (path, line)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.blue.strong))
                    }
                    .buttonStyle(.plain)
                    .help(L("Comment on this line"))
                }
            }
            .frame(width: 22)
            number(line.old)
            number(line.new)
            Text(sign)
                .frame(width: 14)
                .foregroundStyle(signTone)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.role == .hunk ? Theme.textDim : Theme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(Theme.mono(size: 11.5))
        .frame(height: line.role == .hunk ? 24 : 18)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(Theme.mono(size: 10))
            .foregroundStyle(Theme.textFaint)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var sign: String {
        switch line.role {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var signTone: Color {
        line.role == .added ? Theme.greenTone.strong : Theme.redTone.strong
    }

    private var background: Color {
        switch line.role {
        case .added: Theme.greenTone.soft
        case .removed: Theme.redTone.soft
        case .hunk: Theme.blue.soft.opacity(0.6)
        case .context: hovered ? Theme.fillHover : .clear
        }
    }
}

private struct CommentCard: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.blue.strong)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            IconButton(symbol: "trash", help: L("Remove comment"), action: remove)
        }
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.blue.soft))
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
    }
}

private struct CommentEditor: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(L("What should the agent change here?"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1 ... 6)
                .focused($focused)
                .onSubmit { onSave(text) }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.textPrimary.opacity(0.3), lineWidth: 1)
                )
            HStack(spacing: 8) {
                Button(L("Cancel"), action: onCancel).buttonStyle(.link)
                Button(L("Add comment")) { onSave(text) }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.system(size: 12))
        }
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .onAppear { focused = true }
        .onExitCommand(perform: onCancel)
    }
}
