import SwiftUI

@MainActor
enum TaskResolver {
    static func workspace(for target: TaskTarget) -> Workspace? {
        if let issue = target.issue, let workspace = HubModel.shared.session(for: issue) { return workspace }
        return Store.shared.workspaces.first { target.root != nil && $0.context.root == target.root && $0.context.branch == target.branch }
    }

    static func work(for target: TaskTarget) -> WorkItem? {
        if let workspace = workspace(for: target), let item = WorkLedger.shared.item(for: workspace) { return item }
        return WorkLedger.shared.items.values.first {
            if let issue = target.issue { return $0.issue?.repo.lowercased() == issue.repo.lowercased() && $0.issue?.number == issue.number }
            return $0.root == target.root && $0.branch == target.branch
        }
    }
}

struct TaskDecision: Identifiable {
    var target: TaskTarget
    var reason: String
    var action: String
    var rank: Int
    var id: String { target.id }

    @MainActor static func items() -> [TaskDecision] {
        var decisions: [String: TaskDecision] = [:]
        for workspace in Store.shared.orderedWorkspaces where workspace.context.repo != nil {
            let target = TaskTarget(workspace: workspace)
            let step = Flow.next(for: workspace)
            if case let .failed(reason) = Landing.shared.step(for: workspace) {
                decisions[target.id] = TaskDecision(target: target, reason: reason, action: L("Inspect the failure"), rank: 1)
                continue
            }
            let decision: TaskDecision?
            switch step {
            case .answer:
                decision = TaskDecision(target: target, reason: L("The agent needs an answer."), action: L("Answer"), rank: 0)
            case .approvePlan:
                decision = TaskDecision(target: target, reason: L("The plan is ready for your decision."), action: L("Read the plan"), rank: 1)
            case .accept:
                decision = TaskDecision(target: target, reason: L("Try the implementation and check the acceptance criteria."), action: L("Inspect and accept"), rank: 2)
            case let .fix(reason):
                decision = TaskDecision(target: target, reason: reason, action: L("Inspect the failure"), rank: 3)
            case .land:
                guard Queue.shared.landingBlocker(for: workspace) == nil else { continue }
                decision = TaskDecision(target: target, reason: L("The reviewed pull request is ready to merge."), action: L("Land"), rank: 4)
            default:
                if workspace.agent == .failed {
                    decision = TaskDecision(target: target, reason: L("The agent stopped on an error."), action: L("Inspect the failure"), rank: 0)
                } else if case let .failed(reason) = Landing.shared.step(for: workspace) {
                    decision = TaskDecision(target: target, reason: reason, action: L("Inspect the failure"), rank: 1)
                } else { decision = nil }
            }
            if let decision { decisions[target.id] = decision }
        }
        for item in Queue.shared.items {
            let reason: String
            switch item.phase {
            case let .needsYou(text), let .failed(text): reason = text
            case .planReady: reason = L("The plan is ready for your decision.")
            default: continue
            }
            let target = TaskTarget(issue: item.issue)
            if decisions[target.id] == nil {
                decisions[target.id] = TaskDecision(target: target, reason: reason, action: L("Open task"), rank: 1)
            }
        }
        for receipt in Landing.shared.journal.receipts.values where receipt.step.isActive {
            let work = WorkLedger.shared.items[receipt.id]
                ?? WorkItem(root: receipt.root, branch: receipt.branch, title: receipt.branch, pr: receipt.pr,
                            created: receipt.started, touched: receipt.since)
            let target = TaskTarget(work: work)
            if TaskResolver.workspace(for: target) == nil, decisions[target.id] == nil {
                decisions[target.id] = TaskDecision(target: target,
                    reason: L("A saved workflow needs its checkout reconnected."), action: L("Reconnect task"), rank: 1)
            }
        }
        return decisions.values.sorted { ($0.rank, $0.target.title, $0.id) < ($1.rank, $1.target.title, $1.id) }
    }
}

struct DecisionsPage: View {
    @ObservedObject var window: WindowModel
    @ObservedObject private var store = Store.shared
    @ObservedObject private var queue = Queue.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var acceptance = Acceptance.shared
    @ObservedObject private var quorum = QuorumWatch.shared

    var body: some View {
        let decisions = TaskDecision.items()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(L("Needs you"))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 6)
                Text(decisions.isEmpty ? L("No decisions waiting. Work can continue.") : L("Decide here; the task keeps its context."))
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.bottom, 20)
                ForEach(decisions) { decision in
                    Button { window.openTask(decision.target) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            StateMark(word: "", tone: Theme.orange.strong, size: 12, dot: true).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(decision.target.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                Text(decision.reason).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                                if let issue = decision.target.issue {
                                    Text(issue.repo + " #\(issue.number)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                                }
                            }
                            Spacer(minLength: 12)
                            Text(decision.action).font(.system(size: 12)).foregroundStyle(Theme.textBody)
                            Icon("chevron.right", size: 10).foregroundStyle(Theme.textDim)
                        }
                        .padding(.vertical, 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                if let problem = queue.problem { Text(problem).foregroundStyle(Theme.textMuted).padding(.top, 16) }
                if let problem = landing.journal.problem { Text(problem).foregroundStyle(Theme.textMuted).padding(.top, 16) }
            }
            .padding(24)
        }
    }
}

/// The work keeps one destination through implementation, acceptance and landing.
struct TaskPage: View {
    let target: TaskTarget
    @ObservedObject var window: WindowModel
    @ObservedObject private var store = Store.shared
    @ObservedObject private var ledger = TaskLedger.shared
    @ObservedObject private var work = WorkLedger.shared
    @ObservedObject private var queue = Queue.shared
    @ObservedObject private var results = Results.shared
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var acceptance = Acceptance.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    private var section: String {
        get { window.taskSection }
        nonmutating set { window.taskSection = newValue }
    }
    @State private var issue: Issue?
    @State private var issueProblem: String?
    @State private var review: ReviewModel?
    @State private var criterion = ""
    @State private var goal = ""
    @State private var editingGoal = false
    @State private var reply = ""
    @State private var githubIssueState: String?
    @State private var starting = false
    @State private var startProblem: String?
    @AppStorage(AgentKind.defaultKey) private var defaultAgent = AgentKind.preferredChoice()
    @State private var agentOverride: String?
    private var preferredAgent: String { agentOverride ?? defaultAgent }

    private var workspace: Workspace? { TaskResolver.workspace(for: target) }
    private var item: WorkItem? { TaskResolver.work(for: target) }
    private var record: TaskRecord { ledger.record(for: target) }
    private var githubRequest: TaskGitHubRequest? {
        let root = workspace?.context.root ?? target.root
        guard let repo = (issue ?? target.issue)?.repo ?? item?.repo ?? root.flatMap({ quorum.slugs[$0] }) else { return nil }
        return TaskGitHubRequest(repo: repo, issue: (issue ?? target.issue)?.number, pr: workspace?.context.pr ?? item?.pr)
    }
    private var startIssue: Issue? {
        guard workspace == nil, item?.isOpen != true, target.branch == nil,
              var issue = issue ?? target.issue, !queue.contains(issue) else { return nil }
        if let githubIssueState { issue.state = githubIssueState }
        return issue.isOpen ? issue : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            switch section {
            case "implementation": implementation
            case "reviews": reviews
            case "activity": activity
            case "queue":
                if let issue = issue ?? target.issue { TaskQueueSettings(issue: issue).padding(24) }
                else { TaskBudgetSettings(target: target).padding(24) }
            default: overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: target.id) { await loadIssue() }
        .task(id: workspace.map { "\($0.id)|\($0.context.checkout ?? "")|\($0.sessions.contains(where: { $0.preparing != nil }))" }) {
            if let workspace, !workspace.sessions.contains(where: { $0.preparing != nil }) {
                review = ReviewModel(workspace: workspace, scope: .branch, purpose: .acceptance)
            } else { review = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { window.taskTarget = nil } label: {
                    HStack(spacing: 5) { Icon("chevron.left", size: 10); Text(L("Hub")) }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                Spacer()
                if let workspace {
                    SmallButton(title: L("Terminal"), symbol: "terminal") {
                        window.showHub = false
                        window.select(workspace)
                    }
                }
                if let next = TaskDecision.items().first(where: { $0.id != target.id }) {
                    SmallButton(title: L("Next decision"), symbol: "chevron.right") { window.openTask(next.target) }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text((issue ?? target.issue)?.repo ?? item?.repo ?? target.root ?? L("Task"))
                        .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    Text((issue ?? target.issue)?.heading ?? target.title)
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    if let workspace { Text(Flow.next(for: workspace).title).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                }
                Spacer(minLength: 0)
                taskAction
            }
            if let request = githubRequest {
                TaskGitHubStatus(request: request, issueState: $githubIssueState, onIssue: applyIssue).id(request)
            }
            if let issue = startIssue {
                HStack(spacing: 12) {
                    let agent = AgentKind(rawValue: preferredAgent)
                    PanelButton(title: starting ? L("Starting task…") : (agent.map { L("Start with %@", $0.name) } ?? L("Open terminal")), symbol: "play.fill", prominent: true) {
                        starting = true
                        startProblem = nil
                        let done: (String?) -> Void = { id in
                            starting = false
                            if id == nil { startProblem = L("Task could not start. Check the repository checkout and agent setup.") }
                        }
                        if let agent { HubModel.shared.start(issue, agents: [agent], in: window, hideHub: false, then: done) }
                        else { HubModel.shared.startTerminal(issue, in: window, hideHub: false, then: done) }
                    }.disabled(starting)
                    Picker(L("Agent"), selection: Binding(get: { preferredAgent }, set: { agentOverride = $0 })) {
                        ForEach(AgentKind.allCases) { Text($0.name).tag($0.rawValue) }
                        Text(L("Terminal only")).tag(AgentKind.shell)
                    }.labelsHidden().frame(width: 110).disabled(starting)
                    Text(agent == nil ? L("Opens a terminal in its own checkout.") : L("Starts an agent in its own checkout."))
                        .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
            }
            if let startProblem { Text(startProblem).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            Segments(selection: Binding(get: { section }, set: { section = $0 }), options: [("overview", L("Overview")), ("implementation", L("Implementation")),
                ("reviews", L("Reviews")), ("activity", L("Activity")), ("queue", L("Queue & limits"))])
        }
    }

    @ViewBuilder private var taskAction: some View {
        if let workspace {
            let next = Flow.next(for: workspace)
            if landing.step(for: workspace)?.isActive == true {
                SmallButton(title: L("Pause automation")) { landing.cancel(workspace) }
            } else { switch next {
            case .accept:
                SmallButton(title: L("Inspect and accept"), prominent: true) { section = "implementation" }
            case .answer, .approvePlan:
                SmallButton(title: next.title) { section = "overview" }
            case .land, .review, .fix, .openPR:
                SmallButton(title: next.title) {
                    if let reason = queue.landingBlocker(for: workspace) { window.show(reason); return }
                    if !Flow.take(next, in: workspace, window: window) {
                        window.show(L("The request could not be delivered. Check the terminal and try again."))
                    }
                }
            default: EmptyView()
            } }
        } else if let item, item.isOpen {
            SmallButton(title: L("Continue")) { work.resume(item, in: window); window.showHub = true }
        } else if let root = target.root, let branch = target.branch {
            SmallButton(title: L("Open checkout")) {
                guard let directory = HubModel.worktree(of: branch, root: root) else {
                    window.show(L("Its checkout is gone.")); return
                }
                let workspace = Store.shared.makeWorkspace(directory: directory, in: window)
                window.select(workspace)
                window.showHub = true
            }
        }
    }

    private var overview: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        SectionLabel(L("Goal"), tone: Theme.textMuted)
                        Spacer()
                        SmallButton(title: L("Edit")) { editingGoal.toggle() }
                    }
                    if editingGoal {
                        TextEditor(text: $goal).font(.system(size: 13)).scrollContentBackground(.hidden)
                            .frame(minHeight: 70, maxHeight: 120)
                            .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.fillHover))
                        SmallButton(title: L("Save goal")) {
                            if ledger.update(target.id, { $0.goal = goal; $0.customGoal = true }) { editingGoal = false }
                        }
                    } else {
                        Text(goal).font(.system(size: 13)).foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    criteria
                    if let body = issue?.body ?? record.issueBody, !body.isEmpty {
                        DisclosureGroup(L("Issue description")) {
                            MarkdownText(text: body).padding(.top, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    if let issueProblem { Text(issueProblem).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                    if let workspace, let summary = results.result(for: workspace)?.summary {
                        SectionLabel(L("What the agent did"), tone: Theme.textMuted)
                        Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.textBody).textSelection(.enabled)
                    }
                    if let problem = ledger.problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    decision
                    proof
                    if let workspace {
                        let collisions = Radar.shared.collisions(for: workspace.context.checkout)
                        if !collisions.isEmpty {
                            SectionLabel(L("Collisions"), tone: Theme.textMuted)
                            ForEach(Array(collisions.enumerated()), id: \.offset) { _, collision in
                                Text((collision.withBase ? collision.baseName : Radar.shared.title(of: collision.other)) + ": " + collision.files.joined(separator: ", "))
                                    .font(.system(size: 12)).foregroundStyle(Theme.textBody)
                            }
                        }
                    }
                    if let item, !item.evidence.isEmpty { EvidenceButton(item: item) }
                    if let queued = queue.items.first(where: { $0.id.lowercased() == target.id.lowercased() }), let reason = queue.reason(for: queued) {
                        Text(reason).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                }
                .frame(width: 310, alignment: .leading)
            }
            .padding(24)
        }
    }

    private var criteria: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L("Acceptance criteria"), tone: Theme.textMuted)
            Text(L("Checks apply to the current pull request commit."))
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            ForEach(record.criteria) { criterion in
                Toggle(isOn: Binding(get: { criterion.checked(at: workspace?.context.prHead) }, set: { checked in
                    ledger.update(target.id) { value in
                        if let index = value.criteria.firstIndex(where: { $0.id == criterion.id }) {
                            value.criteria[index].checkedHead = checked ? workspace?.context.prHead : nil
                        }
                    }
                })) { Text(criterion.text).font(.system(size: 12.5)).foregroundStyle(Theme.textBody) }
                .toggleStyle(.checkbox).disabled(workspace?.context.prHead == nil)
                .contextMenu {
                    Button(L("Remove")) { ledger.update(target.id) { $0.removeCriterion(criterion) } }
                }
            }
            HStack(spacing: 8) {
                TextField(L("Add acceptance criterion …"), text: $criterion).textFieldStyle(.roundedBorder)
                    .onSubmit(addCriterion)
                SmallButton(title: L("Add"), action: addCriterion)
            }
        }
        .disabled(workspace.map { landing.step(for: $0)?.isActive == true } ?? false)
    }

    @ViewBuilder private var decision: some View {
        if let workspace {
            let next = Flow.next(for: workspace)
            SectionLabel(L("Next step"), tone: Theme.textMuted)
            Text(next.title.isEmpty ? L("No action needed.") : next.title).font(.system(size: 13)).foregroundStyle(Theme.textBody)
            if case .answer = next, let agent = workspace.sessions.first(where: { $0.agent == .blocked }) {
                if let text = agent.terminalView.currentSurface?.readText(screen: true), !text.isEmpty {
                    Text(String(text.suffix(6000))).font(Theme.mono(size: 11)).foregroundStyle(Theme.textBody)
                        .textSelection(.enabled)
                }
                let choices = Inbox.choices(of: agent)
                ForEach(choices, id: \.number) { choice in
                    SmallButton(title: choice.label) { _ = Inbox.choose(choice, in: agent) }
                }
                TextField(L("Your answer …"), text: $reply).textFieldStyle(.roundedBorder)
                SmallButton(title: L("Send answer")) {
                    if Inbox.reply(reply, to: agent) { reply = "" }
                }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if case .approvePlan = next {
                Text(L("Read the agent's plan in the terminal before approving it."))
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                SmallButton(title: L("Approve the plan")) {
                    if let item = queue.item(for: workspace), item.phase == .planReady { queue.approve(item) }
                    else if !Flow.take(next, in: workspace, window: window) {
                        window.show(L("The request could not be delivered. Check the terminal and try again."))
                    }
                }
            }
            if let step = landing.step(for: workspace) {
                Text(step.text).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        } else if let issue, !issue.isOpen {
            SectionLabel(L("Next step"), tone: Theme.textMuted)
            Text(L("This issue is closed.")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
        } else {
            SectionLabel(L("Next step"), tone: Theme.textMuted)
            Text(item?.isOpen == true ? L("Continue the saved conversation in its checkout.") : L("Start or queue this issue to begin."))
                .font(.system(size: 12)).foregroundStyle(Theme.textBody)
        }
    }

    @ViewBuilder private var proof: some View {
        if let workspace {
            if let result = Proofs.shared.result(for: workspace.context.checkout) {
                SectionLabel(L("Last checks"), tone: Theme.textMuted)
                Text(String(result.tree.prefix(12)) + " · " + result.finished.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.mono(size: 10.5)).foregroundStyle(Theme.textDim)
                ForEach(Array(result.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StateMark(word: "", tone: entry.outcome == .passed ? Theme.greenTone.strong : entry.outcome == .failed ? Theme.orange.strong : Theme.textDim, size: 12, dot: true)
                        Text(entry.name).font(.system(size: 12)).foregroundStyle(Theme.textBody)
                        Spacer()
                        Text(String(format: "%.0f s", entry.seconds)).font(Theme.mono(size: 10.5)).foregroundStyle(Theme.textDim)
                    }
                    if entry.outcome == .failed {
                        Text(String(entry.tail.suffix(1500))).font(Theme.mono(size: 11)).foregroundStyle(Theme.textMuted).textSelection(.enabled)
                    }
                }
            }
            if let checkout = workspace.context.checkout, let root = workspace.context.root {
                SmallButton(title: L("Run checks")) { Proofs.shared.run(checkout: checkout, root: root, session: workspace.agentTab) }
                    .disabled(Proofs.shared.isRunning(checkout))
            }
        }
    }

    @ViewBuilder private var implementation: some View {
        if let review {
            ReviewView(model: review, embedded: true) { }
        } else {
            empty(L("Start or continue the task to inspect its implementation."))
        }
    }

    @ViewBuilder private var reviews: some View {
        if let workspace, let status = quorum.status(for: workspace) {
            QuorumRunPage(status: status) { section = "overview" }
        } else if let repo = item?.repo, let pr = item?.pr, let status = quorum.byKey["\(repo)#\(pr)"] {
            QuorumRunPage(status: status) { section = "overview" }
        } else { empty(L("No review run for this task yet.")) }
    }

    private var activity: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let head = record.lastInspectedHead {
                    SectionLabel(L("Last inspection"), tone: Theme.textMuted)
                    Text(String(head.prefix(12)) + (record.inspectedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                        .font(Theme.mono(size: 11)).foregroundStyle(Theme.textBody)
                }
                if let root = target.root ?? item?.root ?? workspace?.context.root,
                   let branch = target.branch ?? item?.branch ?? workspace?.context.branch,
                   let receipt = landing.journal.receipts[WorkItem.key(root: root, branch: branch)] {
                    SectionLabel(L("Automation"), tone: Theme.textMuted)
                    Text(receipt.step.text).font(.system(size: 12.5)).foregroundStyle(Theme.textBody)
                    Text(L("%d repair requests", receipt.asks)).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
                SectionLabel(L("Feedback"), tone: Theme.textMuted)
                if record.feedback.isEmpty { Text(L("No feedback sent yet.")).font(.system(size: 12)).foregroundStyle(Theme.textDim) }
                ForEach(record.feedback.reversed()) { feedback in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(feedback.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                        Text(feedback.text).font(.system(size: 12.5)).foregroundStyle(Theme.textBody).textSelection(.enabled)
                        if let path = feedback.screenshot {
                            SmallButton(title: L("Screenshot")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        }
                    }
                }
                SectionLabel(L("Evidence"), tone: Theme.textMuted)
                ForEach(Array((item?.evidence ?? []).reversed().enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        StateMark(word: "", tone: fact.ok == true ? Theme.greenTone.strong : fact.ok == false ? Theme.orange.strong : Theme.textDim, size: 12, dot: true)
                        Text(fact.text).font(.system(size: 12.5)).foregroundStyle(Theme.textBody)
                        Spacer()
                        Text(fact.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
    }

    private func empty(_ message: String) -> some View {
        Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func addCriterion() {
        let text = criterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if ledger.update(target.id, { $0.criteria.append(TaskCriterion(text: text)) }) { criterion = "" }
    }

    private func loadIssue() async {
        issue = target.issue
        goal = record.goal.isEmpty ? target.title : record.goal
        agentOverride = nil
    }

    private func applyIssue(_ value: Issue) {
        let previousGoal = record.goal.isEmpty ? target.title : record.goal
        let previousTitle = issue?.title ?? target.issue?.title ?? target.title
        issue = value
        issueProblem = nil
        ledger.update(target.id) { $0.synchronize(value, previousTitle: previousTitle) }
        if !editingGoal, goal == previousGoal { goal = record.goal }
    }
}

struct TaskQueueSettings: View {
    let issue: Issue
    @ObservedObject private var queue = Queue.shared
    @ObservedObject private var usage = Usage.shared
    @State private var dependencies = Set<String>()
    @State private var limits = AutomationLimits()
    @State private var message: String?

    private var item: Queue.Item? { queue.items.first { $0.issue.repo.lowercased() == issue.repo.lowercased() && $0.issue.number == issue.number } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel(L("Queue & limits"), tone: Theme.textMuted)
                if let item {
                    HStack(spacing: 12) {
                        Text(item.phase.description).font(.system(size: 13)).foregroundStyle(Theme.textBody)
                        if item.phase.isActive {
                            SmallButton(title: L("Pause automation")) { queue.pause(item) }
                        } else if item.phase != .queued {
                            SmallButton(title: L("Continue with a new budget")) { queue.retry(item) }
                        }
                    }
                    HStack(spacing: 10) {
                        if queue.running {
                            SmallButton(title: L("Stop new starts")) { queue.stop() }
                        } else if queue.items.contains(where: { $0.phase == .queued }) {
                            SmallButton(title: L("Start queue")) { queue.start() }
                        }
                    }
                    if let reason = queue.reason(for: item) { Text(reason).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                    if let started = item.started {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(L("Elapsed: %@ · %d of %d review attempts", QuorumRunView.duration(context.date.timeIntervalSince(started)), item.babysits, (item.limits ?? AutomationLimits()).reviewAttempts))
                                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        }
                    }
                    ForEach(usage.windows(item.agent), id: \.name) { window in
                        let percent = String(format: "%.0f%%", window.used)
                        let reset = window.resets.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
                        Text("\(item.agent.name) · \(window.name): \(percent)\(reset)")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    }
                    SectionLabel(L("Start after these issues are merged"), tone: Theme.textMuted)
                    Text(L("A successful review or a closed issue does not release a dependency."))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    ForEach(queue.items.filter { $0.id != item.id }) { other in
                        Toggle(isOn: Binding(get: { dependencies.contains(other.id) }, set: { checked in
                            if checked { dependencies.insert(other.id) } else { dependencies.remove(other.id) }
                        })) { Text(other.id + " · " + other.issue.title).font(.system(size: 12)) }
                        .toggleStyle(.checkbox).disabled(item.phase.isActive)
                    }
                    if queue.items.count == 1 { Text(L("Queue another issue to add a prerequisite.")).font(.system(size: 12)).foregroundStyle(Theme.textDim) }
                    Stepper(L("Time limit: %d hours", limits.hours), value: $limits.hours, in: 1...48).disabled(item.phase.isActive)
                    Stepper(L("Review attempts: %d", limits.reviews), value: $limits.reviews, in: 0...10).disabled(item.phase.isActive)
                    Stepper(L("Repair requests per landing: %d", limits.repairs), value: $limits.repairs, in: 0...10).disabled(item.phase.isActive)
                    SmallButton(title: L("Save dependencies and limits")) {
                        message = queue.configure(item, dependencies: Array(dependencies), limits: limits) ?? L("Saved")
                    }.disabled(item.phase.isActive)
                    Text(L("The time limit pauses further muxy actions. Work already running in quorum or GitHub is tracked separately."))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                } else if !issue.isOpen {
                    Text(L("This issue is closed.")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                } else {
                    Text(L("Add this issue to the queue to set dependencies and limits."))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textMuted)
                    HStack(spacing: 8) {
                        SmallButton(title: L("Queue for Claude")) { queue.add(issue, agent: .claude); load() }
                        SmallButton(title: L("Queue for Codex")) { queue.add(issue, agent: .codex); load() }
                    }
                }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                if let problem = queue.problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).font(.system(size: 12.5))
        }
        .onAppear(perform: load)
    }

    private func load() {
        dependencies = Set(item?.dependencies ?? [])
        limits = item?.limits ?? AutomationLimits()
    }
}

extension Queue.Phase {
    var description: String {
        switch self {
        case .queued: L("Queued")
        case .running: L("Working")
        case .ready: L("Ready")
        case .planReady: L("Plan ready")
        case let .needsYou(text), let .failed(text): text
        }
    }
}


struct TaskBudgetSettings: View {
    let target: TaskTarget
    @ObservedObject private var ledger = TaskLedger.shared
    @State private var limits = AutomationLimits()
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel(L("Automation limits"), tone: Theme.textMuted)
            Stepper(L("Time limit: %d hours", limits.hours), value: $limits.hours, in: 1...48)
            Stepper(L("Review attempts: %d", limits.reviews), value: $limits.reviews, in: 0...10)
            Stepper(L("Repair requests per landing: %d", limits.repairs), value: $limits.repairs, in: 0...10)
            SmallButton(title: L("Save limits")) { saved = ledger.update(target.id) { $0.limits = limits } }
            if saved { Text(L("Saved")).foregroundStyle(Theme.textDim) }
            if let problem = ledger.problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            Text(L("Dependencies are available when the task belongs to a queued issue."))
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            Spacer()
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { limits = ledger.record(for: target).limits ?? AutomationLimits() }
    }
}
