import SwiftUI
import Combine
import AppKit
import WebKit

/// What a session's agent changed, file by file: in its last turn, on
/// the whole branch, or in any earlier turn. Comments on lines go to the
/// agent in one message. Opens over the stage (⇧⌘D).
@MainActor
final class ReviewModel: ObservableObject {
    enum Purpose { case changes, acceptance }
    enum Scope: Hashable {
        case lastTurn
        case branch
        case sinceInspection(String)
        /// One recorded turn: from the checkpoint before it to this one.
        case turn(Checkpoint)
    }

    let workspace: Workspace
    let checkout: String
    let root: String
    let purpose: Purpose
    @Published private(set) var inspectionBaseline: String?
    @Published var scope: Scope
    @Published private(set) var files: [FileDiff] = []
    @Published var selected: String?
    @Published private(set) var loading = false
    @Published private(set) var note: String?
    @Published private(set) var readiness: Acceptance.Readiness = .checking
    @Published var comments: [ReviewComment] = []
    /// The line a comment is being written for.
    @Published var drafting: (path: String, line: FileDiff.Line)?
    private var token = 0
    private var workspaceChanges: AnyCancellable?

    init?(workspace: Workspace, scope: Scope = .lastTurn, purpose: Purpose = .changes) {
        guard let checkout = workspace.context.checkout, let root = workspace.context.root else { return nil }
        self.workspace = workspace
        self.checkout = checkout
        self.root = root
        self.scope = scope
        self.purpose = purpose
        self.inspectionBaseline = TaskLedger.shared.record(for: TaskTarget(workspace: workspace)).lastInspectedHead
        workspaceChanges = workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var additions: Int { files.map(\.additions).reduce(0, +) }
    var deletions: Int { files.map(\.deletions).reduce(0, +) }
    var selectedFile: FileDiff? { files.first { $0.path == selected } ?? files.first }

    /// The tab the comments go to: the one running an agent.
    var agentSession: TerminalSession? {
        workspace.agentTab
    }

    var feedbackAgent: AgentKind {
        AgentKind.preferred()
    }

    func load() {
        token += 1
        let token = token
        loading = true
        if purpose == .acceptance { readiness = .checking }
        let scope = scope
        let checkout = checkout
        let root = root
        let checkpoints = Turns.shared.checkpoints(for: checkout)
        let expected = workspace.context.prHead
        let accepting = purpose == .acceptance
        Task.detached(priority: .userInitiated) {
            let (files, note) = Self.diff(scope: scope, checkout: checkout, root: root, checkpoints: checkpoints)
            let readiness = accepting ? Acceptance.readiness(checkout: checkout, expected: expected) : .unavailable
            await MainActor.run {
                guard token == self.token else { return }
                self.loading = false
                self.files = files
                self.note = note
                self.readiness = readiness
                if !files.contains(where: { $0.path == self.selected }) { self.selected = files.first?.path }
            }
        }
    }

    nonisolated static func diff(
        scope: Scope, checkout: String, root: String, checkpoints: [Checkpoint]
    ) -> ([FileDiff], String?) {
        switch scope {
        case .lastTurn:
            // The turn's start: its own "before", else (nothing changed in
            // between, so none was written) the turn before's end.
            let latestAfter = checkpoints.firstIndex { $0.moment == .after }
            let start: Checkpoint? = {
                guard let first = checkpoints.first else { return nil }
                if first.moment == .before { return first }
                guard let latestAfter else { return nil }
                return checkpoints.dropFirst(latestAfter + 1).first
            }()
            guard let before = start else {
                let (files, _) = diff(scope: .branch, checkout: checkout, root: root, checkpoints: checkpoints)
                return (files, L("No turn recorded yet: the whole branch instead."))
            }
            guard let now = WorkState.snapshot(of: checkout) else { return ([], nil) }
            return (Diffs.load(from: before.commit, to: now.commit, in: checkout), nil)
        case .branch:
            guard let now = WorkState.snapshot(of: checkout),
                  let base = WorkState.base(of: checkout, root: root) else { return ([], nil) }
            return (Diffs.load(from: base, to: now.commit, in: checkout), nil)
        case let .sinceInspection(head):
            guard head.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil,
                  let now = WorkState.snapshot(of: checkout) else { return ([], L("The previous inspection could not be read.")) }
            let exists = Shell.execute(WorkState.git, ["cat-file", "-e", head + "^{commit}"], in: checkout)
            guard exists.status == 0 else { return ([], L("The previously inspected commit is no longer available.")) }
            return (Diffs.load(from: head, to: now.commit, in: checkout), nil)
        case let .turn(checkpoint):
            // The checkpoint just older than this one.
            let older = checkpoints.drop { $0.ref != checkpoint.ref }.dropFirst().first
            let base = older?.commit ?? (checkpoint.commit + "^")
            return (Diffs.load(from: base, to: checkpoint.commit, in: checkout), nil)
        }
    }

    @discardableResult
    func rememberInspection() -> Bool {
        guard let head = readiness.head else { return false }
        guard TaskLedger.shared.update(TaskTarget(workspace: workspace).id, {
            $0.lastInspectedHead = head
            $0.inspectedAt = Date()
        }) else { return false }
        inspectionBaseline = head
        if case .sinceInspection = scope { scope = .sinceInspection(head) }
        return true
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
        guard RemoteState.type(ReviewMessage.compose(comments), enter: true, into: session) else { return false }
        comments = []
        return true
    }

    func sendFeedback(_ feedback: String, screenshot: URL?) -> Bool {
        let existing = agentSession
        guard Landing.shared.step(for: workspace)?.isActive != true,
              QuorumWatch.shared.status(for: workspace)?.running != true else { return false }
        if let existing {
            guard existing.agent != .working, existing.terminalView.currentSurface != nil else { return false }
        }
        guard let message = AcceptanceFeedback.compose(
            feedback: feedback, screenshot: screenshot, comments: comments, checkout: checkout,
            repo: workspace.context.repo, pr: workspace.context.pr, newChat: existing == nil
        ) else { return false }
        let target = TaskTarget(workspace: workspace)
        var receipt = TaskFeedback(text: message, head: workspace.context.prHead, screenshot: screenshot?.path)
        guard TaskLedger.shared.update(target.id, { record in
            receipt = record.stageFeedback(receipt)
            record.draft = feedback
            record.lastInspectedHead = readiness.head ?? record.lastInspectedHead
            record.inspectedAt = Date()
        }) else { return false }
        guard Queue.shared.followDecision(in: workspace, awaitingAgent: true) else { return false }
        let delivered: Bool
        if let session = existing {
            delivered = RemoteState.type(message, enter: true, into: session)
        } else {
            // A PR opened from the hub may have only a shell tab. Start the
            // preferred agent in this checkout with the feedback as its first
            // prompt; typing into a just-created terminal would lose it.
            let kind = feedbackAgent
            let conversation = kind == .claude ? UUID().uuidString.lowercased() : nil
            let skipPermissions = Store.shared.skipPermissions
            let session = TerminalSession(
                directory: checkout,
                command: Launcher.shellCommand(running: kind.command(.new(prompt: true, id: conversation), skipPermissions: skipPermissions)),
                environment: ["MUXY_PROMPT": message]
            )
            session.kind = kind
            session.agentSessionID = conversation
            session.skipsPermissions = skipPermissions
            session.issue = workspace.sessions.compactMap(\.issue).first
            session.agent = .idle
            guard BackgroundStart.start(session) else { return false }
            Store.shared.add(session, to: workspace)
            Store.shared.sessionsChanged()
            delivered = true
        }
        guard delivered else {
            Queue.shared.deliveryFailed(in: workspace, message: L("Feedback could not be delivered. Check the terminal and send it again."))
            return false
        }
        guard TaskLedger.shared.update(target.id, { record in
            record.commitFeedback(receipt)
            record.draft = ""
        }) else { return false }
        inspectionBaseline = readiness.head ?? inspectionBaseline
        if case .sinceInspection = scope, let inspectionBaseline { scope = .sinceInspection(inspectionBaseline) }
        comments = []
        Queue.shared.resume()
        return true
    }
}

enum AcceptanceFeedback {
    static func compose(feedback: String, screenshot: URL?, comments: [ReviewComment],
                        checkout: String, repo: String?, pr: Int?, newChat: Bool) -> String? {
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty || screenshot != nil || !comments.isEmpty else { return nil }
        var parts: [String] = []
        if newChat {
            let prName = pr.map { " PR #\($0)" } ?? ""
            parts.append("Work in the existing checkout at \(checkout) on \(repo ?? "this repository")\(prName). Inspect the current branch before changing it. Do not create another worktree.")
        }
        if !note.isEmpty { parts.append("I inspected the implementation before quorum. Please change this:\n\(note)") }
        if let screenshot { parts.append("Screenshot of the current preview: \(screenshot.path). Inspect it when addressing my feedback.") }
        if !comments.isEmpty { parts.append(ReviewMessage.compose(comments)) }
        parts.append("Commit and push your changes. I will inspect the updated result before quorum runs.")
        return parts.joined(separator: "\n\n")
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
    var embedded = false
    let close: () -> Void
    @ObservedObject private var taskLedger = TaskLedger.shared
    @State private var surface: AcceptanceSurface = .preview
    @State private var feedback = ""
    @State private var screenshot: URL?
    @State private var accepting = false
    @State private var feedbackProblem: String?
    @State private var criteriaProblem: String?
    @State private var synchronizingCriteria = false
    @State private var criteriaSynchronized = false
    @State private var acceptanceBrowser = WKWebView(frame: .zero)
    @State private var previewDevice: AcceptanceDevice = .desktop
    @State private var previewLandscape = false

    private enum AcceptanceSurface { case preview, code }

    var body: some View {
        VStack(spacing: 0) {
            if model.purpose == .acceptance { acceptanceHeader } else { header }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if model.purpose == .acceptance {
                HStack(spacing: 0) {
                    acceptanceContent
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    acceptancePanel.frame(width: 270)
                }
            } else {
                codeContent
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(embedded ? 0 : 0.14), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            turns.refresh(model.checkout)
            model.load()
            if model.purpose == .acceptance {
                feedback = taskLedger.record(for: TaskTarget(workspace: model.workspace)).draft
            }
            if model.purpose == .acceptance,
               !Previews.shared.ports(of: model.workspace).contains(where: \.isWeb) {
                surface = .code
            }
        }
        .task(id: model.purpose == .acceptance ? model.workspace.context.prHead : nil) {
            guard model.purpose == .acceptance else { return }
            await synchronizeCriteria()
        }
        .onChange(of: model.scope) { model.load() }
        .onChange(of: model.workspace.context.prHead) { model.load() }
        .onChange(of: feedback) {
            guard model.purpose == .acceptance else { return }
            taskLedger.update(TaskTarget(workspace: model.workspace).id) { $0.draft = feedback }
        }
        .onExitCommand(perform: embedded ? nil : close)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("muxy.debug.reviewFeedback"))) { note in
            if let value = note.object as? String { feedback = value }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("muxy.debug.reviewSurface"))) { note in
            if let value = note.object as? String { surface = value == "code" ? .code : .preview }
        }
        #endif
    }

    private var codeContent: some View {
        HStack(spacing: 0) {
            fileList.frame(width: 230)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            diffPane
        }
    }

    private var acceptanceHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(L("Inspect the implementation"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let pr = model.workspace.context.pr { Badge(text: "PR #\(pr)", tone: Theme.blue) }
                }
                Text(model.workspace.sessions.compactMap(\.issue).first?.heading ?? model.workspace.title)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: $surface) {
                Text(L("App preview")).tag(AcceptanceSurface.preview)
                Text(L("Code changes")).tag(AcceptanceSurface.code)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            IconButton(symbol: "arrow.clockwise", help: L("Reload"), action: reloadAcceptance)
            if !embedded { IconButton(symbol: "xmark", help: L("Close (esc)"), action: close) }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    @ViewBuilder
    private var acceptanceContent: some View {
        switch surface {
        case .preview:
            AcceptancePreview(workspace: model.workspace, browser: acceptanceBrowser,
                              device: $previewDevice, landscape: $previewLandscape, screenshot: $screenshot)
        case .code:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("", selection: $model.scope) {
                        Text(L("Whole branch")).tag(ReviewModel.Scope.branch)
                        if let baseline = model.inspectionBaseline {
                            Text(L("Since last inspection")).tag(ReviewModel.Scope.sinceInspection(baseline))
                        }
                    }.labelsHidden().fixedSize()
                    if model.loading { ProgressView().controlSize(.mini) }
                    else { Text(L("%d files · +%d −%d", model.files.count, model.additions, model.deletions))
                        .font(Theme.label(size: 11)).foregroundStyle(Theme.textDim) }
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 30)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                codeContent
            }
        }
    }

    private var acceptancePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 7) {
                Icon(model.readiness.head == nil ? "circle.dotted" : "checkmark.circle", size: 12)
                    .foregroundStyle(model.readiness.head == nil ? Theme.orange.strong : Theme.greenTone.strong)
                Text(model.readiness.message)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            }
            if synchronizingCriteria {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("Refreshing acceptance criteria …"))
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            }
            if let problem = criteriaProblem ?? feedbackProblem ?? taskLedger.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SmallButton(title: L("Remember inspected state")) { _ = model.rememberInspection() }
                .disabled(model.readiness.head == nil)
            if screenshot != nil { Badge(text: L("Screenshot attached"), tone: Theme.blue) }
            if !model.comments.isEmpty { Badge(text: L("%d code comments", model.comments.count), tone: Theme.blue) }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            acceptanceCriteria
            Text(L("Feedback for the agent"))
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textMuted)
            TextEditor(text: $feedback)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .frame(height: 116)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bg))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                .overlay(alignment: .topLeading) {
                    if feedback.isEmpty {
                        Text(L("What should the agent change?"))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                            .padding(.leading, 11).padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
            Button(model.agentSession == nil ? L("Start %@ with feedback", model.feedbackAgent.name) : L("Send feedback")) { sendFeedback() }
                .disabled(model.workspace.agent == .working || Landing.shared.step(for: model.workspace)?.isActive == true || QuorumWatch.shared.status(for: model.workspace)?.running == true || (feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && screenshot == nil && model.comments.isEmpty))
                .frame(maxWidth: .infinity)
            Spacer(minLength: 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Button {
                approve()
            } label: {
                if accepting { ProgressView().controlSize(.small) }
                else { Text(L("Approve implementation")) }
            }
            .disabled(taskLedger.problem != nil || Landing.shared.step(for: model.workspace)?.isActive == true || !criteriaSynchronized || synchronizingCriteria || !taskLedger.record(for: TaskTarget(workspace: model.workspace)).satisfied(at: model.workspace.context.prHead) || model.readiness.head == nil || accepting || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.comments.isEmpty)
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            Text(Landing.shared.withQuorum
                 ? L("Then muxy runs checks and quorum, and merges when the PR is green.")
                 : L("Then muxy runs checks and merges when the PR is green."))
                .font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.surface)
    }

    @ViewBuilder private var acceptanceCriteria: some View {
        let target = TaskTarget(workspace: model.workspace)
        let record = taskLedger.record(for: target)
        if !record.criteria.isEmpty {
            SectionLabel(L("Acceptance criteria"), tone: Theme.textMuted)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(record.criteria) { criterion in
                        Toggle(isOn: Binding(get: { criterion.checked(at: model.workspace.context.prHead) }, set: { checked in
                            taskLedger.update(target.id) { record in
                                if let index = record.criteria.firstIndex(where: { $0.id == criterion.id }) {
                                    record.criteria[index].checkedHead = checked ? model.workspace.context.prHead : nil
                                }
                            }
                        })) { Text(criterion.text).font(.system(size: 11.5)).foregroundStyle(Theme.textBody) }
                        .toggleStyle(.checkbox).disabled(model.readiness.head == nil || Landing.shared.step(for: model.workspace)?.isActive == true)
                    }
                }
            }.frame(maxHeight: 150)
        }
    }

    private func sendFeedback() {
        if model.sendFeedback(feedback, screenshot: screenshot) {
            feedback = ""
            screenshot = nil
            feedbackProblem = nil
            if !embedded { close() }
        } else {
            feedbackProblem = taskLedger.problem ?? Queue.shared.problem ?? L("The agent could not receive feedback. Your draft was kept.")
        }
    }

    private func approve() {
        let inspectedHead = model.readiness.head
        accepting = true
        Task {
            let state = await Acceptance.shared.approve(model.workspace, inspectedHead: inspectedHead)
            accepting = false
            model.load()
            guard state.head != nil else { feedbackProblem = state.message; return }
            if !embedded { close() }
            TaskLedger.shared.inspect(model.workspace, head: state.head)
            guard Queue.shared.followDecision(in: model.workspace, awaitingAgent: false) else {
                feedbackProblem = Queue.shared.problem
                return
            }
            Landing.shared.land(model.workspace)
            Queue.shared.resume()
        }
    }

    private func synchronizeCriteria() async {
        criteriaSynchronized = false
        synchronizingCriteria = true
        criteriaProblem = nil
        let synchronized = await Acceptance.shared.synchronizeCriteria(for: model.workspace)
        guard !Task.isCancelled else { return }
        synchronizingCriteria = false
        criteriaSynchronized = synchronized
        if !synchronized {
            criteriaProblem = L("Could not refresh the linked issue's acceptance criteria. Try reloading.")
        }
    }

    private func reloadAcceptance() {
        model.load()
        Task { await synchronizeCriteria() }
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
                    else { Store.shared.window(of: model.workspace)?.show(L("Comments could not be delivered. Check the terminal and try again."), seconds: 5) }
                } label: {
                    HStack(spacing: 6) {
                        Icon("paperplane.fill", size: 10.5)
                        Text(model.comments.count == 1 ? L("Send 1 comment to the agent") : L("Send %d comments to the agent", model.comments.count))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.textPrimary))
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

/// A separate browser for human acceptance, so the session's own preview
/// keeps its page and history while this panel is open.
private enum AcceptanceDevice: String, CaseIterable {
    case desktop, phone, tablet

    var title: String {
        switch self {
        case .desktop: L("Desktop")
        case .phone: L("Phone")
        case .tablet: L("Tablet")
        }
    }

    func viewport(in available: CGSize, landscape: Bool) -> CGSize {
        switch self {
        case .desktop: available
        case .phone: landscape ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 844)
        case .tablet: landscape ? CGSize(width: 1180, height: 820) : CGSize(width: 820, height: 1180)
        }
    }
}

private struct AcceptancePreview: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var previews = Previews.shared
    let browser: WKWebView
    @Binding var device: AcceptanceDevice
    @Binding var landscape: Bool
    @Binding var screenshot: URL?
    @State private var selectedPort: Int?
    @State private var address = ""
    @State private var problem: String?

    private var webPorts: [AppPort] { previews.ports(of: workspace).filter(\.isWeb) }
    private var port: Int? {
        if let selectedPort, webPorts.contains(where: { $0.port == selectedPort }) { return selectedPort }
        return webPorts.first?.port
    }

    var body: some View {
        VStack(spacing: 0) {
            if let port {
                HStack(spacing: 7) {
                    IconButton(symbol: "chevron.left", help: L("Back")) { browser.goBack() }
                    IconButton(symbol: "arrow.clockwise", help: L("Reload")) { browser.reload() }
                    Text(address.isEmpty ? "localhost:\(port)" : address)
                        .font(Theme.label(size: 11)).foregroundStyle(Theme.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if webPorts.count > 1 {
                        Picker("", selection: $selectedPort) {
                            ForEach(webPorts, id: \.port) { app in
                                Text(verbatim: ":\(app.port)").tag(Optional(app.port))
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Button(L("Capture screenshot")) { capture() }
                        .font(.system(size: 11.5))
                    IconButton(symbol: "safari", help: L("Open in Browser")) {
                        NSWorkspace.shared.open(browser.url ?? URL(string: "http://localhost:\(port)/")!)
                    }
                }
                .padding(.horizontal, 10).frame(height: 36)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 10) {
                    Picker("", selection: $device) {
                        ForEach(AcceptanceDevice.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    if device != .desktop {
                        Button(landscape ? L("Portrait") : L("Landscape")) { landscape.toggle() }
                            .font(.system(size: 11.5))
                    }
                    Spacer()
                    if device != .desktop {
                        let size = device.viewport(in: .zero, landscape: landscape)
                        Text(verbatim: "\(Int(size.width)) × \(Int(size.height))")
                            .font(Theme.label(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 10).frame(height: 34)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                GeometryReader { geometry in
                    let size = device.viewport(in: geometry.size, landscape: landscape)
                    let inset: CGFloat = device == .desktop ? 0 : 16
                    let scale = min(1, (geometry.size.width - inset * 2) / max(size.width, 1),
                                    (geometry.size.height - inset * 2) / max(size.height, 1))
                    ReviewBrowser(view: browser)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(max(scale, 0.1))
                        .frame(width: size.width * max(scale, 0.1), height: size.height * max(scale, 0.1))
                        .background(.white)
                        .overlay {
                            if device != .desktop {
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(Theme.border, lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.bg)
                }
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Theme.orange.strong)
                        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Icon("rectangle.on.rectangle", size: 28).foregroundStyle(Theme.textDim)
                    Text(L("No running app preview"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(L("Start the app in this session. Its web preview will appear here automatically. You can inspect the code changes now."))
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center).frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
        }
        .onAppear {
            selectedPort = port
            load(port)
        }
        .onChange(of: port) { _, newPort in
            selectedPort = newPort
            load(newPort)
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            let shown = browser.url.map(Self.address) ?? ""
            if shown != address { address = shown }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("muxy.debug.previewDevice"))) { note in
            guard let value = note.object as? String else { return }
            let parts = value.split(separator: "-")
            guard let first = parts.first, let next = AcceptanceDevice(rawValue: String(first)) else { return }
            device = next
            landscape = parts.dropFirst().first == "landscape"
        }
        #endif
    }

    private func load(_ port: Int?) {
        guard let port else { return }
        if browser.url?.port == port { return }
        browser.load(URLRequest(url: URL(string: "http://localhost:\(port)/")!))
    }

    private static func address(_ url: URL) -> String {
        var text = url.host() ?? ""
        if let port = url.port { text += ":\(port)" }
        text += url.path()
        if let query = url.query() { text += "?" + query }
        return text
    }

    private func capture() {
        browser.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                problem = error?.localizedDescription ?? L("Could not capture the preview")
                return
            }
            let directory = URL(fileURLWithPath: StateDirectory.path).appendingPathComponent("acceptance", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(UUID().uuidString + ".png")
                try png.write(to: file, options: .atomic)
                screenshot = file
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private struct ReviewBrowser: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context _: Context) -> WKWebView { view }
    func updateNSView(_: WKWebView, context _: Context) {}
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
                Icon(symbol, size: 9.5)
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
                    Badge(text: "\(comments)", tone: Theme.blue)
                }
                Text("+" + String(file.additions)).foregroundStyle(Theme.greenTone.strong)
                Text("−" + String(file.deletions)).foregroundStyle(Theme.redTone.strong)
            }
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                        Icon("plus", size: 8.5)
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.blue.strong))
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
            Icon("text.bubble.fill", size: 10.5)
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
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.blue.soft))
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
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
