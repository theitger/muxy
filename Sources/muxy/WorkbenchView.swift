import SwiftUI

/// Repository tools and terminal tabs share a workspace; processes survive view changes.
struct WorkbenchView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject private var results = Results.shared
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var acceptance = Acceptance.shared
    @ObservedObject private var radar = Radar.shared

    private var availableSections: [WorkSection] {
        var sections: [WorkSection] = [.terminal]
        if workspace.context.checkout != nil, workspace.context.root != nil { sections.append(.inspect) }
        if quorum.status(for: workspace) != nil || workspace.quorumReference != nil { sections.append(.quorum) }
        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            if !window.isTerminalFocused {
                if availableSections.count > 1 { sectionBar }
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onChange(of: availableSections) {
            if window.workSection == .quorum, !availableSections.contains(.quorum) { window.showSection(.terminal) }
            if window.workSection == .inspect, workspace.context.checkout == nil { window.showSection(.terminal) }
        }
    }

    private var taskMenu: some View {
        Menu {
            if let root = workspace.context.root, let checkout = workspace.context.checkout, !ProofCheck.load(root: root).isEmpty {
                Button(L("Run Checks")) { proofs.run(checkout: checkout, root: root, session: workspace.primary) }
            }
            if workspace.context.repo != nil {
                Button(L("Task details")) { window.openTask(TaskTarget(workspace: workspace)) }
                let record = TaskLedger.shared.record(for: TaskTarget(workspace: workspace))
                if !record.feedback.isEmpty || record.lastInspectedHead != nil || WorkLedger.shared.item(for: workspace)?.evidence.isEmpty == false {
                    Button(L("Activity")) { window.openTask(TaskTarget(workspace: workspace), section: "activity") }
                }
                if results.result(for: workspace) != nil || proofs.result(for: workspace.context.checkout) != nil {
                    Button(L("Checks & result")) { window.showSection(.result) }
                }
                Divider()
                Button(L("Queue & limits")) {
                    window.taskSection = "queue"
                    window.showSection(.overview)
                }
            }
            Button(L("Close session")) { store.requestCloseWorkspace(workspace) }
        } label: { Icon("ellipsis", size: 15).foregroundStyle(Theme.textBody).frame(width: 26, height: 26) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder private func nextAction(_ step: NextStep) -> some View {
        switch step {
        case .answer:
            ActionButton(title: L("Answer in terminal"), symbol: "terminal", primary: true) { revealAgent(needing: .blocked) }
        case .approvePlan:
            ActionButton(title: L("Read the plan"), symbol: "terminal", primary: true) { revealAgent(needing: .blocked, planning: true) }
            ActionButton(title: L("Approve the plan"), symbol: "checkmark") { take(step) }
        case .accept:
            if window.workSection != .inspect {
                ActionButton(title: L("Inspect and accept"), symbol: "eye", primary: true) { window.showSection(.inspect) }
            }
        case .openPR, .review, .fix, .land:
            ActionButton(title: step.title, symbol: "arrow.right", primary: true) { take(step) }
        case .landing, .reviewing:
            if landing.step(for: workspace)?.isActive == true {
                ActionButton(title: L("Pause automation"), symbol: "pause.fill") { landing.cancel(workspace) }
            }
        default:
            if workspace.agent == .failed {
                ActionButton(title: L("Inspect the failure"), symbol: "terminal") { window.showSection(.terminal) }
            }
        }
    }

    private func revealAgent(needing state: AgentState, planning: Bool = false) {
        if let session = workspace.sessions.first(where: { planning ? Flow.planReady($0) : $0.agent == state }) {
            workspace.selectedSessionID = session.id
        }
        window.showSection(.terminal)
    }

    private func take(_ step: NextStep) {
        if step == .land, let reason = Queue.shared.landingBlocker(for: workspace) { window.show(reason); return }
        if !Flow.take(step, in: workspace, window: window) {
            window.show(L("The request could not be delivered. Check the terminal and try again."), seconds: 5)
        }
    }

    private var sectionBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(availableSections) { section in
                        Button {
                            window.taskSection = "overview"
                            window.showSection(section)
                        } label: {
                            HStack(spacing: 6) {
                                Icon(section.symbol, size: 12)
                                Text(section.title).font(UI.control)
                                if section == .quorum, quorum.status(for: workspace)?.running == true {
                                    Circle().fill(Theme.greenTone.strong).frame(width: 5, height: 5)
                                }
                            }
                            .foregroundStyle(window.workSection == section ? Theme.textPrimary : Theme.textMuted)
                            .padding(.horizontal, 11).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 7).fill(window.workSection == section ? Theme.fillActive : .clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(section.purpose)
                    }
                }
            }.scrollIndicators(.never)
            nextAction(Flow.next(for: workspace))
            taskMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    @ViewBuilder private var content: some View {
        switch window.workSection {
        case .terminal:
            VStack(spacing: 0) {
                TabBarView(store: store, window: window, workspace: workspace)
                if window.isTerminalFocused {
                    WorkspaceContent(workspace: workspace)
                } else {
                    WithPreview(workspace: workspace, cornerRadius: 0) {
                        WorkspaceContent(workspace: workspace)
                    }
                }
            }
        case .inspect:
            if let model = window.review {
                ReviewView(model: model, embedded: true) { window.showSection(.terminal) }
            } else if workspace.context.checkout != nil, workspace.context.root != nil {
                WorkspaceInspection(workspace: workspace, window: window)
                    .id("\(workspace.id)|\(workspace.context.checkout ?? "")")
            } else {
                unavailable(title: L("Not a git checkout: nothing to review"), detail: "")
            }
        case .quorum:
            quorumContent
        case .overview:
            if workspace.context.repo != nil {
                TaskPage(target: TaskTarget(workspace: workspace), window: window, embedded: true, activeSection: window.taskSection)
            } else {
                unavailable(title: L("A terminal for anything"), detail: L("Use the shell freely. Repository context appears when you enter a checkout."))
            }
        case .result:
            ResultOverlay(window: window, workspace: workspace, embedded: true)
        case .activity:
            if workspace.context.repo != nil {
                TaskPage(target: TaskTarget(workspace: workspace), window: window, embedded: true, activeSection: "activity")
            } else {
                unavailable(title: L("No task activity yet"), detail: L("Feedback and inspection history stay with repository tasks."))
            }
        }
    }

    @ViewBuilder private var quorumContent: some View {
        if let status = quorum.status(for: workspace) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("Quorum").font(UI.title).foregroundStyle(Theme.textPrimary)
                    Text(status.title ?? "\(status.repo) #\(status.number ?? 0)")
                        .font(UI.metadata).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer()
                    IconButton(symbol: "arrow.clockwise", help: L("Reload")) { quorum.refresh() }
                }
                QuorumRunView(key: status.key, source: status, fullWidth: true)
                    .id(status.runDirectory ?? status.key)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("No review data available")).font(UI.heading)
                if let log = workspace.quorumReference?.log, FileManager.default.fileExists(atPath: log) {
                    ActionButton(title: L("Log"), symbol: "terminal") { window.showSection(.terminal) }
                }
                ActionButton(title: L("Reload"), symbol: "arrow.clockwise") { quorum.refresh() }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func unavailable(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(UI.title).foregroundStyle(Theme.textPrimary)
            Text(detail).font(UI.body).foregroundStyle(Theme.textMuted)
            ActionButton(title: L("Back to work"), symbol: "terminal") { window.showSection(.terminal) }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Construct the review when this pane enters the view tree. Its state belongs
/// to one checkout; no asynchronous setup can race with a context refresh.
private struct WorkspaceInspection: View {
    @ObservedObject var window: WindowModel
    @State private var model: ReviewModel?

    init(workspace: Workspace, window: WindowModel) {
        self.window = window
        _model = State(initialValue: ReviewModel(workspace: workspace, scope: .branch, purpose: .acceptance))
    }

    var body: some View {
        if let model {
            ReviewView(model: model, embedded: true) { window.showSection(.terminal) }
        }
    }
}
