import SwiftUI

/// The hub (⌘H): all work in one place, from the issue assigned to you to
/// the merged pull request. Columns follow a task through its life; the
/// worktrees page shows every checkout on disk and what can go.
struct HubView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject private var hub = HubModel.shared
    @ObservedObject private var inventory = InventoryModel.shared
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var queue = Queue.shared
    @ObservedObject private var work = WorkLedger.shared
    private var page: String {
        get { window.libraryPage }
        nonmutating set { window.libraryPage = newValue }
    }
    /// Board filters: an organization, a repository (both "" for all), and
    /// only issues an agent can take on its own.
    @AppStorage("hubOrg") private var org = ""
    @AppStorage("hubRepo") private var repo = ""
    @AppStorage("hubReadyOnly") private var readyOnly = false
    @State private var cardHeight: CGFloat = 180
    @State private var taskSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14)
            if page == "board", window.reviewRun == nil, window.taskTarget == nil {
                if hub.awaitingFirstResponse { SkeletonFilters() } else { filterBar }
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14)
            }
            if let target = window.taskTarget {
                TaskPage(target: target, window: window).id(target.id)
            } else if let run = window.reviewRun {
                QuorumRunPage(status: run) { window.reviewRun = nil }
            } else if page == "queue" {
                queuePage
            } else if page == "worktrees" {
                WorktreesPage(window: window)
            } else if page == "attention" {
                DecisionsPage(window: window)
            } else if page == "reviews" {
                ReviewsPage(window: window)
            } else {
                board
            }
        }
        .background(Theme.bg)
        .onAppear {
            hub.refresh()
            if page == "worktrees" { inventory.scan() }
        }
        .onChange(of: page) {
            if page == "worktrees" { inventory.scan() }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("muxy.debug.taskSearch"))) {
            taskSearch = $0.object as? String ?? ""
        }
        #endif
        .onExitCommand {
            if window.taskTarget != nil { window.taskTarget = nil }
            else if window.reviewRun != nil { window.reviewRun = nil }
            else { window.showHub = false }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if store.sidebarVisible {
                Text(pageTitle).font(UI.title).foregroundStyle(Theme.textPrimary)
            } else {
                Menu {
                    Button(L("Tasks")) { window.openLibrary() }
                    Button(L("Queue")) { window.openLibrary("queue") }
                    Button(L("Needs you")) { window.openLibrary("attention") }
                    Button(L("Reviews")) { window.openLibrary("reviews") }
                    Button(L("Worktrees")) { window.openLibrary("worktrees") }
                } label: { Text(pageTitle).font(UI.heading) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
            if page == "board", window.taskTarget == nil, window.reviewRun == nil {
                searchField
            }
            account
            IconButton(symbol: "arrow.clockwise", help: L("Refresh")) {
                hub.refresh()
                radar.scan()
                if page == "worktrees" { inventory.scan() }
            }

        }
        .padding(.horizontal, 14)
        .frame(height: 64)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Icon("magnifyingglass", size: 13).foregroundStyle(Theme.textMuted)
            TextField(L("Search tasks, repositories, labels …"), text: $taskSearch)
                .textFieldStyle(.plain).font(UI.control)
                .onExitCommand { taskSearch = "" }
            if !taskSearch.isEmpty {
                IconButton(symbol: "xmark", help: L("Clear search")) { taskSearch = "" }
            }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .frame(minWidth: 180, maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fillHover))
        .accessibilityLabel(L("Search tasks"))
    }

    private var hasQuery: Bool { !taskSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var pageTitle: String {
        if window.taskTarget != nil { return L("Task") }
        if window.reviewRun != nil { return L("Review") }
        switch page {
        case "queue": return L("Queue")
        case "attention": return L("Needs you")
        case "reviews": return L("Reviews")
        case "worktrees": return L("Worktrees")
        default: return L("Tasks")
        }
    }

    @ViewBuilder
    private var account: some View {
        if let login = hub.account.login {
            Button {
                if let profile = hub.account.profile { NSWorkspace.shared.open(profile) }
            } label: {
                HStack(spacing: 7) {
                    AsyncImage(url: hub.account.avatar) { image in
                        image.resizable().interpolation(.high)
                    } placeholder: {
                        Circle().fill(Theme.fillActive)
                    }
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hub.account.name ?? login).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        if hub.account.name != nil {
                            Text("@" + login).font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Signed in to GitHub through gh. Opens your profile."))
        } else if let problem = hub.account.problem {
            HStack(spacing: 8) {
                Text(problem).font(UI.metadata).foregroundStyle(Theme.orange.strong)
                SmallButton(title: L("Sign in to GitHub"), prominent: true) {
                    hub.signIn(in: window)
                }
            }
        } else if hub.awaitingFirstResponse {
            SkeletonAccount()
        }
    }

    // MARK: Board

    private var board: some View {
        let sessions = store.orderedWorkspaces.filter {
            visible($0) && searches($0) && ($0.agent != .none || $0.context.pr != nil || $0.sessions.contains { $0.issue != nil })
        }
        let working = sessions.filter { column(of: $0) == .working || column(of: $0) == .none }
        let review = sessions.filter { column(of: $0) == .review }
        let ready = sessions.filter { column(of: $0) == .ready }
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !working.isEmpty {
                    taskGroup(L("Working"), count: working.count) {
                        ForEach(working) { SessionCard(workspace: $0, window: window) }
                    }
                }
                if !review.isEmpty {
                    taskGroup(L("In review"), count: review.count) {
                        ForEach(review) { SessionCard(workspace: $0, window: window) }
                    }
                }
                if !ready.isEmpty {
                    taskGroup(L("Ready to land"), count: ready.count) {
                        ForEach(ready) { SessionCard(workspace: $0, window: window) }
                    }
                }
                if !paused.isEmpty {
                    taskGroup(L("Without an open session"), count: paused.count) {
                        ForEach(paused) { item in PausedCard(item: item) { work.resume(item, in: window) } }
                    }
                }
                if !pulls.isEmpty {
                    taskGroup(L("Your PRs without a session"), count: pulls.count) {
                        ForEach(pulls) { pull in
                            let item = workItem(for: pull)
                            PullCard(pull: pull, local: hub.checkout(of: pull.repo) != nil, item: item,
                                     resume: item?.conversation == nil ? nil : { if let item { work.resume(item, in: window) } },
                                     inspect: { hub.open(pull, agent: nil, in: window, inspect: true) }) { agent in
                                hub.open(pull, agent: agent, in: window)
                            }
                        }
                    }
                }
                if !queuedMatches.isEmpty {
                    Button { window.openLibrary("queue") } label: {
                        HStack {
                            Text(L("Queue")).font(UI.heading)
                            Text(String(queuedMatches.count)).font(UI.metadata)
                            Spacer()
                            Text(L("Open")).font(UI.control)
                            Icon("arrow.right", size: 12)
                        }.foregroundStyle(Theme.textBody).padding(14)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fillHover))
                    }.buttonStyle(.plain)
                    if hasQuery {
                        VStack(spacing: 8) {
                            ForEach(queuedMatches) { item in
                                QueueRow(item: item, remove: { queue.remove(item) }, open: {
                                    window.openTask(TaskTarget(issue: item.issue))
                                })
                            }
                        }.modifier(CardBackground())
                    }
                }
                ForEach(issueGroups, id: \.repo) { group in
                    taskGroup(group.repo, count: group.issues.count) {
                        ForEach(group.issues, id: \.self) { issue in
                            IssueCard(issue: issue, local: hub.checkout(of: issue.repo) != nil, showsRepo: false,
                                      inspect: { window.openTask(TaskTarget(issue: issue)) },
                                      queue: { queue.add(issue, agent: $0, plan: $1) },
                                      plan: { hub.start(issue, agents: [$0], in: window, hideHub: true, plan: true) },
                                      startTerminal: { hub.startTerminal(issue, in: window, hideHub: true) }) { agents in
                                hub.start(issue, agents: agents, in: window, hideHub: true)
                            }
                        }
                    }
                }
                let requests = hub.reviews.filter { matches($0.repo) && TaskSearch.matches(taskSearch, fields: [$0.title, $0.repo, "#\($0.number)", $0.author] + $0.labels) }
                if !requests.isEmpty {
                    taskGroup(L("Reviews for you"), count: requests.count) {
                        ForEach(requests) { request in
                            ReviewRequestCard(request: request, local: hub.checkout(of: request.repo)) { reviewWithQuorum(request) }
                        }
                    }
                }
                if hub.awaitingFirstResponse {
                    SkeletonTaskSection(cardHeight: cardHeight)
                }
                if !hub.awaitingFirstResponse, sessions.isEmpty, paused.isEmpty, pulls.isEmpty, openIssues.isEmpty, requests.isEmpty, queuedMatches.isEmpty {
                    PageHeading(title: hasQuery ? L("No matching tasks") : L("No tasks here yet"),
                                subtitle: hasQuery ? L("Try another search or clear the filters.")
                                    : L("Start a task or choose another repository filter."))
                    if hasQuery {
                        ActionButton(title: L("Clear search"), symbol: "xmark") { taskSearch = "" }
                    } else {
                        ActionButton(title: L("New session"), symbol: "plus", primary: true) { window.newTask() }
                    }
                }
            }
            .padding(24)
            .environment(\.taskCardHeight, cardHeight)
            .onPreferenceChange(TaskCardHeightPreference.self) { cardHeight = max(180, $0) }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var queuePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    queueCount(L("Queued"), count: queue.items.filter { $0.phase == .queued }.count)
                    queueCount(L("Working"), count: queue.items.filter { $0.phase.isActive }.count)
                    queueCount(L("Needs you"), count: queue.items.filter {
                        if case .needsYou = $0.phase { return true }
                        if case .failed = $0.phase { return true }
                        return $0.phase == .planReady
                    }.count)
                    queueCount(L("Ready to land"), count: queue.items.filter { $0.phase == .ready }.count)
                }
                QueueSection(queue: queue, window: window)
                if queue.items.isEmpty {
                    Text(L("Add issues from Tasks to the queue using More → Queue for Claude or Codex."))
                        .font(UI.body).foregroundStyle(Theme.textMuted)
                    ActionButton(title: L("Tasks"), symbol: "list.bullet") { window.openLibrary() }
                }
                if let problem = queue.problem {
                    Text(problem).font(UI.body).foregroundStyle(Theme.redTone.strong)
                }
            }
            .padding(24).frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func queueCount(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(count)).font(UI.title).foregroundStyle(Theme.textPrimary)
            Text(title).font(UI.metadata).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.fillHover))
    }

    private func taskGroup<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(UI.heading).foregroundStyle(Theme.textPrimary)
                Text(String(count)).font(UI.metadata).foregroundStyle(Theme.textMuted)
            }
            TaskCardGrid {
                content()
            }
        }
    }

    /// Work whose session was closed before it got a PR, filtered.
    private var paused: [WorkItem] {
        work.withoutSession.filter {
            $0.pr == nil && matches($0.repo ?? "")
                && TaskSearch.matches(taskSearch, fields: [$0.title, $0.repo ?? "", $0.branch] + ($0.issue.map(TaskSearch.fields) ?? []))
        }
    }

    private func workItem(for pull: HubModel.OwnPull) -> WorkItem? {
        guard let branch = pull.branch, let root = hub.checkout(of: pull.repo) else { return nil }
        return work.items[WorkItem.key(root: root, branch: branch)]
    }

    /// Your open PRs no session works on, filtered, latest change first.
    private var pulls: [HubModel.OwnPull] {
        hub.pullsWithoutSession.filter {
            matches($0.repo) && TaskSearch.matches(taskSearch, fields: [$0.title, $0.repo, $0.branch ?? "", "#\($0.number)"]
                                                  + $0.labels + (workItem(for: $0)?.issue.map(TaskSearch.fields) ?? []))
        }
    }

    /// Assigned issues no session works on yet, filtered, newest first.
    private var openIssues: [Issue] {
        hub.issues.filter { issue in
            hub.session(for: issue) == nil && !queue.contains(issue) && matches(issue.repo)
                && TaskSearch.matches(taskSearch, fields: TaskSearch.fields(issue))
                && (!readyOnly || issue.labels.contains("ready-for-agent"))
        }
        .sorted { ($0.created ?? .distantPast, $0.number) > ($1.created ?? .distantPast, $1.number) }
    }

    /// The issues by repository, the repository with the newest first.
    private var issueGroups: [(repo: String, issues: [Issue])] {
        var order: [String] = []
        var groups: [String: [Issue]] = [:]
        for issue in openIssues {
            if groups[issue.repo] == nil { order.append(issue.repo) }
            groups[issue.repo, default: []].append(issue)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private var queuedMatches: [Queue.Item] {
        queue.items.filter { matches($0.issue.repo) && TaskSearch.matches(taskSearch, fields: TaskSearch.fields($0.issue)) }
    }

    private func searches(_ workspace: Workspace) -> Bool {
        let context = workspace.context
        let issues = workspace.sessions.compactMap(\.issue).flatMap(TaskSearch.fields)
        let pull = hub.pulls.first { $0.number == context.pr && hub.checkout(of: $0.repo) == context.root }
        return TaskSearch.matches(taskSearch, fields: [workspace.title, slug(of: workspace) ?? "", context.branch ?? "",
                                                       context.pr.map { "#\($0)" } ?? ""] + issues + (pull?.labels ?? []))
    }

    private func matches(_ slug: String) -> Bool {
        let owner = Issue(repo: slug, number: 0, title: "", url: "", state: "").owner
        return (org.isEmpty || owner.caseInsensitiveCompare(org) == .orderedSame)
            && (repo.isEmpty || slug.caseInsensitiveCompare(repo) == .orderedSame)
    }

    /// A session's repository as GitHub names it, for the filters.
    private func slug(of workspace: Workspace) -> String? {
        workspace.context.root.flatMap { root in hub.checkouts.first { $0.value == root }?.key }
    }

    private func visible(_ workspace: Workspace) -> Bool {
        guard !org.isEmpty || !repo.isEmpty else { return true }
        guard let slug = slug(of: workspace) else { return false }
        return matches(slug)
    }

    // MARK: Filters

    private var filterBar: some View {
        let all = hub.issues.filter { hub.session(for: $0) == nil }
        let orgs = Dictionary(grouping: all, by: \.owner).mapValues(\.count)
        let repos = Dictionary(grouping: all.filter { org.isEmpty || $0.owner.caseInsensitiveCompare(org) == .orderedSame }, by: \.repo)
            .mapValues(\.count)
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                FilterChip(title: L("All"), count: all.count, selected: org.isEmpty && repo.isEmpty) {
                    org = ""
                    repo = ""
                }
                if orgs.count > 1 {
                    ForEach(orgs.keys.sorted(), id: \.self) { name in
                        FilterChip(title: name, count: orgs[name] ?? 0, selected: org == name && repo.isEmpty) {
                            org = name
                            repo = ""
                        }
                    }
                }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
                ForEach(repos.keys.sorted { (repos[$0] ?? 0, $1) > (repos[$1] ?? 0, $0) }, id: \.self) { slug in
                    FilterChip(title: slug.split(separator: "/").last.map(String.init) ?? slug, count: repos[slug] ?? 0,
                               selected: repo == slug) {
                        repo = repo == slug ? "" : slug
                    }
                    .help(slug)
                }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
                FilterChip(title: "ready-for-agent", count: all.filter { $0.labels.contains("ready-for-agent") && matches($0.repo) }.count,
                           selected: readyOnly) {
                    readyOnly.toggle()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    typealias Stage = NextStep.Stage

    private func column(of workspace: Workspace) -> Stage {
        Flow.next(for: workspace).stage
    }

    private func reviewWithQuorum(_ request: HubModel.ReviewRequest) {
        guard let root = hub.checkout(of: request.repo) else {
            NSWorkspace.shared.open(URL(string: request.url) ?? URL(fileURLWithPath: "/"))
            return
        }
        window.showHub = false
        let workspace = store.makeWorkspace(directory: root, in: window)
        window.select(workspace)
        Quorum.run(.review, pr: request.number, in: workspace)
        if let first = workspace.sessions.first, workspace.sessions.count > 1 { store.close(first, in: workspace) }
    }
}

// MARK: Pieces

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceActive))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }
}

private struct IssueCard: View {
    let issue: Issue
    let local: Bool
    var showsRepo = true
    let inspect: () -> Void
    let queue: (AgentKind, Bool) -> Void
    let plan: (AgentKind) -> Void
    let startTerminal: () -> Void
    let start: ([AgentKind]) -> Void
    @AppStorage(AgentKind.defaultKey) private var preferred = AgentKind.preferredChoice()

    var body: some View {
        TaskCardFrame(description: issue.body) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if showsRepo {
                        SectionLabel(issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo).lineLimit(1)
                    }
                    Text("#" + String(issue.number)).font(Theme.label(size: 10.5)).foregroundStyle(Theme.textDim)
                    if let created = issue.created {
                        Text(WorktreeRow.ago(Date().timeIntervalSince(created)))
                            .font(Theme.label(size: 10.5)).foregroundStyle(Theme.textFaint)
                            .help(created.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                }.frame(height: 14)
                Button(action: inspect) {
                    Text(issue.title).font(UI.control).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2, reservesSpace: true)
                    .frame(minHeight: 32, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(issue.title)
                TaskLabels(labels: issue.labels)
            }
        } actions: {
            let agent = AgentKind(rawValue: preferred)
            TaskCardFooter(title: agent.map { L("Start %@", $0.name) } ?? L("Open terminal"),
                           url: issue.url, disabled: !local) {
                if let agent { start([agent]) } else { startTerminal() }
            } more: {
                Button(L("Task"), action: inspect)
                Divider()

                Group {
                    ForEach(AgentKind.allCases) { kind in
                        Button(L("Start %@", kind.name)) { start([kind]) }
                    }
                    Divider()
                    Button(L("Claude and Codex side by side")) { start(AgentKind.allCases) }
                    ForEach(AgentKind.allCases) { kind in
                        Button(L("Plan first with %@", kind.name)) { plan(kind) }
                    }
                    Divider()
                    ForEach(AgentKind.allCases) { kind in
                        Button(L("Queue for %@", kind.name)) { queue(kind, false) }
                    }
                    ForEach(AgentKind.allCases) { kind in
                        Button(L("Queue for %@, plan first", kind.name)) { queue(kind, true) }
                    }
                }.disabled(!local)
            }
        }
    }
}

private struct ReviewRequestCard: View {
    let request: HubModel.ReviewRequest
    let local: String?
    let review: () -> Void

    var body: some View {
        TaskCardFrame(description: request.body) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Icon("arrow.triangle.pull", size: 10).foregroundStyle(Theme.textDim)
                    Text("#" + String(request.number)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim)
                    Text(request.author).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    Spacer()
                }.frame(height: 14)
                Text(request.title)
                    .help(request.title)
                    .font(UI.control)
                    .lineLimit(2, reservesSpace: true)
                    .frame(minHeight: 32, alignment: .topLeading)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                TaskLabels(labels: request.labels)
            }
        } actions: {
            TaskCardFooter(title: local != nil && Quorum.isInstalled ? L("Run quorum") : L("Open on GitHub"), url: request.url) {
                if local != nil, Quorum.isInstalled { review() }
                else if let url = URL(string: request.url) { NSWorkspace.shared.open(url) }
            } more: {
                Button(L("Open on GitHub")) {
                    if let url = URL(string: request.url) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

/// The queue: what waits, what runs, how each one ended, and the
/// button that starts or stops it.
private struct QueueSection: View {
    @ObservedObject var queue: Queue
    @ObservedObject var window: WindowModel
    @AppStorage(Queue.parallelKey) private var parallel = Queue.defaultParallel

    var body: some View {
        let waiting = queue.items.filter { $0.phase == .queued }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionLabel(L("Queue"))
                Text(String(queue.items.count)).font(Theme.label(size: 11)).foregroundStyle(Theme.textDim)
                Spacer()
                if queue.items.contains(where: { $0.phase.isFinished }) {
                    Button(L("Clear finished")) { queue.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
            }
            HStack(spacing: 10) {
                Text(L("Parallel agents")).font(UI.control).foregroundStyle(Theme.textBody)
                Picker(L("Parallel agents"), selection: $parallel) {
                    ForEach(1 ... 5, id: \.self) { Text(String($0)).tag($0) }
                }.labelsHidden().frame(width: 80)
                Spacer()
            }
            if queue.items.isEmpty {
                Text(L("Nothing waits.")).font(UI.body).foregroundStyle(Theme.textMuted).padding(.vertical, 12)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(queue.items) { item in
                    QueueRow(item: item, remove: { queue.remove(item) }, open: {
                        window.openTask(TaskTarget(issue: item.issue))
                    })
                    if item.id != queue.items.last?.id {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
            HStack(spacing: 6) {
                if queue.running, let held = queue.held {
                    SmallButton(title: L("Stop")) { queue.stop() }
                    Text(held).font(.system(size: 10.5)).foregroundStyle(Theme.orange.strong)
                } else if queue.running {
                    SmallButton(title: L("Stop")) { queue.stop() }
                    Text(waiting == 0 ? L("Nothing waits.") : L("%d wait, %d at a time", waiting, parallel))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                } else if waiting > 0 {
                    SmallButton(title: L("Start queue"), prominent: true) { queue.start() }
                    Text(L("%d at a time, no permission prompts", parallel))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                }
            }
        }
        .modifier(CardBackground())
    }
}

private struct QueueRow: View {
    let item: Queue.Item
    let remove: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AgentGlyph(kind: item.agent, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Button(action: open) {
                    Text(item.issue.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary).lineLimit(2)
                }.buttonStyle(.plain)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
                TaskLabels(labels: item.issue.labels)
            }
            Spacer(minLength: 4)
            if item.phase == .planReady {
                Button(L("Approve")) { Queue.shared.approve(item) }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .help(L("The plan is good: the agent goes ahead"))
            }
            if item.phase != .queued {
                Button(L("Open"), action: open).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    .help(item.phase == .planReady ? L("Read the plan") : "")
            }
            if !item.phase.isActive {
                Button(action: remove) { Icon("xmark", size: 9).foregroundStyle(Theme.textDim) }
                    .buttonStyle(.plain)
                    .help(L("Remove from the queue"))
            }
        }
        .padding(.vertical, 6)
    }

    private var detail: String {
        let reason = Queue.shared.reason(for: item) ?? status.text
        return "\(item.issue.repo) #\(item.issue.number) · \(reason)"
    }

    private var status: (text: String, color: Color) {
        switch item.phase {
        case .queued: (L("waits"), Theme.textDim)
        case .running: (L("runs"), Theme.blue.strong)
        case .ready: (L("ready to land"), Theme.greenTone.strong)
        case .planReady: (L("plan ready for your go-ahead"), Theme.blue.strong)
        case let .needsYou(why): (why, Theme.orange.strong)
        case let .failed(why): (why, Theme.redTone.strong)
        }
    }
}

/// A pull request of yours without a session: where it is, and a way back
/// into it, with an agent or a terminal.
private struct PullCard: View {
    let pull: HubModel.OwnPull
    let local: Bool
    var item: WorkItem?
    /// Its agent's conversation picked up again, when there is one.
    var resume: (() -> Void)?
    let inspect: () -> Void
    let open: (AgentKind?) -> Void
    @AppStorage(AgentKind.defaultKey) private var preferred = AgentKind.preferredChoice()
    @ObservedObject private var quorum = QuorumWatch.shared
    @State private var starting = false
    /// Why quorum couldn't start, until the next try.
    @State private var problem: String?

    private var status: QuorumStatus? { quorum.byKey[pull.id] }

    /// What quorum can do for it, as for a session: review and fix, or
    /// again after a run that stopped.
    private var quorumStep: NextStep? {
        guard local, !starting else { return nil }
        guard let step = Flow.quorumStep(status, installed: Quorum.isInstalled, head: pull.head) else { return nil }
        if case .reviewing = step { return nil }
        return step
    }

    private var cardStatus: SessionSummary? {
        guard let status else { return nil }
        return SessionSummary.completedQuorum(status, head: pull.head)
            ?? SessionSummary.resolve(agent: .none, next: quorumStep ?? .none,
                                      quorumRunning: status.running, quorumPhase: status.phase, prState: .open)
    }

    var body: some View {
        TaskCardFrame(description: pull.body ?? HubModel.shared.description(for: item?.issue)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    SectionLabel(pull.repo.split(separator: "/").last.map(String.init) ?? pull.repo).lineLimit(1)
                    Text("#" + String(pull.number)).font(Theme.label(size: 10.5)).foregroundStyle(Theme.textDim)
                    if let updated = pull.updated {
                        Text(WorktreeRow.ago(Date().timeIntervalSince(updated)))
                            .font(Theme.label(size: 10.5)).foregroundStyle(Theme.textFaint)
                            .help(updated.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                }.frame(height: 14)
                Text(pull.title)
                    .help(pull.title + (pull.branch.map { "\n" + $0 } ?? ""))
                    .font(UI.control)
                    .lineLimit(2, reservesSpace: true)
                    .frame(minHeight: 32, alignment: .topLeading)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                TaskLabels(labels: (pull.draft ? [L("Draft")] : []) + pull.labels + (item?.issue?.labels ?? [])
                           + (!local ? [L("Not cloned here")] : pull.branch == nil ? [L("From a fork")] : []),
                           status: cardStatus)
                if let problem {
                    Text(problem).font(UI.metadata).foregroundStyle(Theme.orange.strong)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            let agent = AgentKind(rawValue: preferred)
            TaskCardFooter(title: status?.running == true ? L("Open quorum") : quorumStep != nil ? L("Run quorum") : (resume != nil ? L("Continue") : L("Open session")),
                           url: pull.url, disabled: status?.running == true ? false : (!local || pull.branch == nil), busy: starting) {
                if let status, status.running {
                    (Store.shared.activeWindow ?? Store.shared.windows.first)?.openQuorumRun(status)
                } else if let branch = pull.branch, let root = HubModel.shared.checkout(of: pull.repo), quorumStep != nil {
                    startQuorum(branch: branch, root: root)
                } else if let resume { resume() }
                else { open(agent) }
            } more: {
                if let branch = pull.branch { Text(branch); Divider() }
                Button(L("App & code"), action: inspect).disabled(!local || pull.branch == nil)
                if let item {
                    Button(L("Task")) { (Store.shared.activeWindow ?? Store.shared.windows.first)?.openTask(TaskTarget(work: item)) }
                    if !item.evidence.isEmpty {
                        Button(L("Evidence")) { (Store.shared.activeWindow ?? Store.shared.windows.first)?.openTask(TaskTarget(work: item), section: "activity") }
                    }
                }
                if let status, status.runDirectory != nil {
                    Button(L("Quorum details")) { (Store.shared.activeWindow ?? Store.shared.windows.first)?.openQuorumRun(status) }
                }
                if let log = Quorum.latestLog(pr: pull.number) {
                    Button(L("Log")) {
                        let root = HubModel.shared.checkout(of: pull.repo)
                        let directory = pull.branch.flatMap { branch in root.flatMap { HubModel.worktree(of: branch, root: $0) ?? $0 } } ?? Paths.home
                        Quorum.showLog(log, in: directory, reference: QuorumReference(root: root ?? directory, number: pull.number, repo: pull.repo, log: log))
                    }
                }
                Divider()
                if let resume { Button(L("Continue"), action: resume) }
                ForEach(AgentKind.allCases) { kind in
                    Button(L("New %@ chat", kind.name)) { open(kind) }.disabled(!local || pull.branch == nil)
                }
                Button(L("Terminal only")) { open(nil) }.disabled(!local || pull.branch == nil)
            }
        }
    }

    /// The branch made ready (babysit refuses otherwise), then quorum.
    private func startQuorum(branch: String, root: String) {
        starting = true
        problem = nil
        let number = pull.number
        guard let expectedHead = pull.head else {
            problem = L("Could not verify the commit. Try reloading.")
            starting = false
            return
        }
        Task.detached(priority: .userInitiated) {
            let blocked = Quorum.prepare(branch: branch, root: root, accepted: expectedHead)
            let live = blocked == nil ? Git.pullRequest(in: root, number: number) : .unknown
            await MainActor.run {
                if let blocked {
                    problem = blocked
                    starting = false
                    return
                }
                guard let current = Quorum.openPullRequest(live, number: number, expectedHead: expectedHead) else {
                    problem = switch live {
                    case .unknown: Acceptance.Readiness.unavailable.message
                    case .none, .found: L("The pull request changed. Refresh and try again.")
                    }
                    HubModel.shared.refresh()
                    starting = false
                    return
                }
                // The run live in a session of its own, in its branch's checkout.
                let follow = HubModel.worktree(of: branch, root: root) ?? root
                if !Quorum.start(.babysit, pr: number, draft: current.isDraft, root: root, follow: follow) {
                    problem = L("quorum didn't start.")
                }
                // Until quorum's own files say it runs.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { starting = false }
            }
        }
    }
}

/// Work whose session is closed before it has a PR: where it was, its
/// evidence, a way back into its agent's conversation, or away with it.
private struct PausedCard: View {
    let item: WorkItem
    let resume: () -> Void

    var body: some View {
        TaskCardFrame(description: HubModel.shared.description(for: item.issue)) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    SectionLabel(item.repo?.split(separator: "/").last.map(String.init) ?? Paths.folderName(item.root)).lineLimit(1)
                    Text(WorktreeRow.ago(Date().timeIntervalSince(item.touched)))
                        .font(Theme.label(size: 10.5)).foregroundStyle(Theme.textFaint)
                    Spacer()
                }.frame(height: 14)
                Text(item.title)
                    .help(item.title + "\n" + item.branch)
                    .font(UI.control)
                    .lineLimit(2, reservesSpace: true)
                    .frame(minHeight: 32, alignment: .topLeading)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                TaskLabels(labels: item.issue?.labels ?? [])
            }
        } actions: {
            let agent = item.agent ?? .claude
            TaskCardFooter(title: item.conversation == nil ? L("New %@ chat", agent.name) : L("Continue with %@", agent.name),
                           url: item.issue?.url, action: resume) {
                Text(item.branch)
                Divider()
                Button(L("Task")) { (Store.shared.activeWindow ?? Store.shared.windows.first)?.openTask(TaskTarget(work: item)) }
                if !item.evidence.isEmpty {
                    Button(L("Evidence")) { (Store.shared.activeWindow ?? Store.shared.windows.first)?.openTask(TaskTarget(work: item), section: "activity") }
                }
                Divider()
                Button(L("Remove from board")) { WorkLedger.shared.drop(item) }
            }
        }
    }
}

/// The work's evidence: what was checked, reviewed, fixed and collided,
/// and the PR comment that says it.
struct EvidenceButton: View {
    let item: WorkItem
    @State private var shown = false
    @State private var posted: String?

    var body: some View {
        Button(L("Evidence")) { shown.toggle() }
            .buttonStyle(.plain)
            .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Evidence")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    ForEach(Array(item.evidence.suffix(12).reversed().enumerated()), id: \.offset) { _, fact in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StateMark(word: "", tone: fact.ok == true ? Theme.greenTone.strong
                                : fact.ok == false ? Theme.orange.strong : Theme.textDim, size: 12, dot: true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fact.text).font(UI.metadata).foregroundStyle(Theme.textBody)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(fact.date.formatted(date: .abbreviated, time: .shortened)
                                     + (fact.ref.map { " · " + $0.prefix(12) } ?? ""))
                                    .font(Theme.mono(size: 10)).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                    if let pr = item.pr, item.prState == "open" {
                        HStack(spacing: 8) {
                            SmallButton(title: L("Post on the PR")) { post(pr: pr) }
                            if let posted { Text(posted).font(.system(size: 11)).foregroundStyle(Theme.textDim) }
                        }
                    }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
    }

    /// The evidence as a comment on the pull request.
    private func post(pr: Int) {
        let report = WorkLedger.report(item)
        let directory = item.checkout ?? item.root
        posted = L("Posting …")
        Task.detached(priority: .userInitiated) {
            guard let gh = Shell.find("gh") else { return }
            let result = Shell.execute(gh, ["pr", "comment", String(pr), "--body", report], in: directory, timeout: 60)
            await MainActor.run { posted = result.status == 0 ? L("Posted") : L("Couldn't post: %@", result.error) }
        }
    }
}

/// A session on the board: what it is, where it stands, the next step.
private struct SessionCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var window: WindowModel
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var work = WorkLedger.shared
    @ObservedObject private var hub = HubModel.shared
    @State private var message = ""
    @State private var messaging = false
    @FocusState private var typing: Bool

    private var labels: [String] {
        let linked = workspace.sessions.compactMap(\.issue).flatMap { issue in
            (hub.issues.first { $0.repo.lowercased() == issue.repo.lowercased() && $0.number == issue.number } ?? issue).labels
        }
        guard let root = workspace.context.root else { return linked }
        let pull = hub.pulls.first {
            hub.checkout(of: $0.repo) == root
                && ($0.number == workspace.context.pr || ($0.branch != nil && $0.branch == workspace.context.branch))
        }
        return linked + (pull?.labels ?? [])
    }

    private var description: String? {
        let context = workspace.context
        let issue = workspace.sessions.compactMap(\.issue).first
        if let text = hub.description(for: issue), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        guard let root = context.root else { return nil }
        return hub.pulls.first {
            hub.checkout(of: $0.repo) == root
                && ($0.number == context.pr || ($0.branch != nil && $0.branch == context.branch))
        }?.body
    }

    var body: some View {
        let context = workspace.context
        let next = Flow.next(for: workspace)
        TaskCardFrame(description: description, highlighted: workspace.agent == .blocked) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    SessionTile(agent: workspace.agent, attention: workspace.needsAttention, isGit: true, kind: workspace.agentTab?.kind, size: 12)
                    SectionLabel(context.repo ?? L("Terminal")).lineLimit(1)
                    if let pr = context.pr {
                        Text("#" + String(pr)).font(Theme.label(size: 10.5)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                }.frame(height: 14)
                Text(workspace.title).font(UI.control).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(minHeight: 32, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(workspace.title + (context.branch.map { "\n" + $0 } ?? ""))
                TaskLabels(labels: labels + (context.isDraft ? [L("Draft")] : []), status: workspace.sessionStatus)

            }
        } actions: {
            nextStep(next)
        }
        .popover(isPresented: $messaging) {
            HStack(spacing: 8) {
                TextField(L("Message the agent …"), text: $message)
                    .textFieldStyle(.plain).font(UI.body).focused($typing).onSubmit(send)
                IconButton(symbol: "paperplane.fill", help: L("Send (↩)"), action: send)
            }
            .padding(14).frame(width: 320)
            .onAppear { typing = true }
        }
        .contentShape(Rectangle())
        // The card is the way in: one click and you're in its terminal.
        .onTapGesture { open() }
        .contextMenu {
            Button(L("Open")) { open() }
            if context.checkout != nil {
                Button(L("Review Changes")) { window.openReview(workspace, scope: .branch) }
            }
            if workspace.variantGroup != nil {
                Button(L("Keep This Variant")) { FanOut.confirmKeep(workspace) }
            }
        }
    }

    /// The suggested step as a button, or what it waits for; plus the
    /// way into the session and its changes.
    private func nextStep(_ next: NextStep) -> some View {
        let actionable: Bool = switch next {
        case .wait, .reviewing, .landing, .none: false
        default: true
        }
        let reviewing = quorum.status(for: workspace)?.running == true
        let title = reviewing ? L("Open quorum") : next == .review ? L("Run quorum") : (actionable ? next.title : L("Open session"))
        return TaskCardFooter(title: title, url: workspace.pullRequestURL?.absoluteString) {
            if reviewing { window.showSection(.quorum) }
            else if actionable {
                if !Flow.take(next, in: workspace, window: window) {
                    window.show(L("The request could not be delivered. Check the terminal and try again."))
                }
            } else { open() }
        } more: {
            if let branch = context.branch { Text(branch); Divider() }
            if quorum.status(for: workspace) != nil {
                Button(L("Quorum details")) { window.select(workspace); window.showSection(.quorum) }
            }
            Button(L("Task")) { window.openTask(TaskTarget(workspace: workspace)) }
            Button(L("Terminal")) { open() }
            if context.checkout != nil {
                Button(L("App & code")) { window.select(workspace); window.showSection(.inspect) }
                Button(L("Changes")) { window.openReview(workspace, scope: .branch) }
            }
            if let item = work.item(for: workspace), !item.evidence.isEmpty {
                Button(L("Evidence")) { window.openTask(TaskTarget(workspace: workspace), section: "activity") }
            }
            if workspace.agentTab != nil {
                Button(L("Message the agent …")) { messaging = true }
            }
            if workspace.variantGroup != nil {
                Button(L("Keep This Variant")) { FanOut.confirmKeep(workspace) }
            }
        }
    }

    private var context: RepoContext { workspace.context }

    private func open() {
        window.showHub = false
        window.select(workspace)
        window.focusTerminal()
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let agent = workspace.agentTab else { return }
        guard RemoteState.type(text, enter: true, into: agent) else {
            window.show(L("The message could not be delivered. Check the terminal and try again."))
            return
        }
        message = ""
        messaging = false
    }
}

// MARK: Worktrees

private struct WorktreesPage: View {
    @ObservedObject var window: WindowModel
    @ObservedObject private var inventory = InventoryModel.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        let list = inventory.worktrees
        let finished = list.filter { $0.isFinished && $0.owner != .quorum && !inventory.hasSession($0) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !inventory.hasScanned {
                    SkeletonGroup { SkeletonBar(width: 160, height: 12) }
                } else {
                    Text(L("%d worktrees · %d finished", list.filter { $0.owner != .main }.count, finished.count))
                        .font(UI.metadata).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                if list.contains(where: { $0.owner == .quorum }), Quorum.isInstalled {
                    SmallButton(title: L("quorum gc")) {
                        inventory.quorumGC { window.show(L("quorum cleaned its cache")) }
                    }
                    .help(L("quorum's own cleanup for its run folders"))
                }
                if !finished.isEmpty {
                    SmallButton(title: L("Remove %d finished", finished.count), prominent: true) {
                        confirmRemove(finished)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !inventory.hasScanned, list.isEmpty {
                        SkeletonGroup { SkeletonBar(width: 110, height: 11) }
                        SkeletonList(kind: .worktrees)
                    }
                    ForEach(Dictionary(grouping: list, by: \.root).keys.sorted(), id: \.self) { root in
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel((root as NSString).lastPathComponent)
                            ForEach(list.filter { $0.root == root }.sorted(by: order)) { info in
                                WorktreeRow(info: info, hasSession: inventory.hasSession(info),
                                            removing: inventory.removing.contains(info.path),
                                            open: { open(info) }, remove: { confirmRemove([info]) })
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    /// Main first, then work in progress, then what's done, oldest last.
    private func order(_ a: WorktreeInfo, _ b: WorktreeInfo) -> Bool {
        func rank(_ info: WorktreeInfo) -> Int { info.owner == .main ? 0 : (info.isFinished ? 2 : 1) }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return (a.lastCommit ?? .distantPast) > (b.lastCommit ?? .distantPast)
    }

    private func open(_ info: WorktreeInfo) {
        window.showHub = false
        if let workspace = store.workspaces.first(where: { $0.context.checkout == info.path }) {
            store.select(workspace)
        } else {
            window.newWorkspace(directory: info.path)
        }
    }

    private func confirmRemove(_ list: [WorktreeInfo]) {
        let risky = list.filter { !$0.isFinished }
        let alert = NSAlert()
        alert.messageText = list.count == 1
            ? L("Remove %@?", Paths.abbreviate(list[0].path))
            : L("Remove %d worktrees?", list.count)
        var detail = risky.isEmpty
            ? L("Nothing in them is lost: no uncommitted changes, nothing unmerged.")
            : L("This one has uncommitted changes or unmerged commits. They are lost with it.")
        detail += " " + L("Containers of their own stop; ones shared with the main checkout are left alone.")
        alert.informativeText = detail
        alert.alertStyle = risky.isEmpty ? .informational : .warning
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        inventory.remove(list) { count in
            window.show(count == 1 ? L("1 worktree removed") : L("%d worktrees removed", count))
        }
    }
}

private struct WorktreeRow: View {
    let info: WorktreeInfo
    let hasSession: Bool
    let removing: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Icon(icon, size: 11)
                .foregroundStyle(Theme.textDim)
                .frame(width: 18)
                .help(ownerText)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.branch ?? L("detached"))
                        .font(UI.control)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let pr = info.pr {
                        Badge(text: "#\(pr)", tone: info.prState == .merged ? Theme.purple : (info.prState == .closed ? Theme.neutral : Theme.blue))
                    }
                    if hasSession { Badge(text: L("open"), tone: Theme.blue) }
                    if info.running > 0, let project = info.containers {
                        Badge(text: L("%d containers", info.running), tone: Theme.yellow)
                            .help(project)
                    }
                }
                Text(Paths.abbreviate(info.path))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(status)
                .font(UI.metadata)
                .foregroundStyle(info.isFinished ? Theme.greenTone.strong : Theme.textMuted)
                .lineLimit(1)
            if let age = info.age {
                Text(Self.ago(age)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.textFaint)
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 2) {
                IconButton(symbol: "arrow.right.circle", help: L("Open a session here"), action: open)
                if info.owner != .main {
                    if removing {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        IconButton(symbol: "trash", help: hasSession ? L("Close its session first") : L("Remove"), action: remove)
                            .disabled(hasSession)
                    }
                }
            }
            .opacity(hovered || removing ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? Theme.fillHover : .clear))
        .onHover { hovered = $0 }
    }

    private var icon: String {
        switch info.owner {
        case .main: "house"
        case .muxy: "square.stack.3d.up"
        case .claude: "sparkle"
        case .quorum: "person.3"
        case .other: "folder"
        }
    }

    private var ownerText: String {
        switch info.owner {
        case .main: L("Main checkout")
        case .muxy: L("Made by muxy")
        case .claude: L("Made by a Claude Code subagent")
        case .quorum: L("quorum's review run")
        case .other: L("Made by hand")
        }
    }

    private var status: String {
        if info.prunable { return L("folder gone") }
        if info.owner == .main { return L("main checkout") }
        if info.spare { return L("ready for the next session") }
        if info.changes < 0 || info.ahead < 0 { return L("git couldn't tell") }
        var parts: [String] = []
        if info.changes > 0 { parts.append(info.changes == 1 ? L("1 change") : L("%d changes", info.changes)) }
        if info.ahead > 0, !info.mergedHere { parts.append(L("%d unmerged", info.ahead)) }
        if parts.isEmpty { return info.mergedHere ? L("merged") : L("nothing of its own") }
        return parts.joined(separator: " · ")
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86400)
        if days >= 30 { return L("%dmo", days / 30) }
        if days >= 1 { return L("%dd", days) }
        let hours = Int(seconds / 3600)
        if hours >= 1 { return L("%dh", hours) }
        let minutes = Int(seconds / 60)
        return minutes >= 1 ? L("%dm", minutes) : L("now")
    }
}

// MARK: Reviews

/// Open PRs first; completed work is available for thirty days.
private struct ReviewsPage: View {
    @ObservedObject var window: WindowModel
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var hub = HubModel.shared
    @State private var lookup = ReviewHistory.Lookup()
    @State private var checking = true
    @State private var hasChecked = false
    @State private var showCompleted = false

    var body: some View {
        let runs = Array(quorum.byKey.values)
        let groups = ReviewHistory.group(runs, states: lookup.states)
        let request = ReviewHistory.Request(keys: runs.map(\.key).sorted(), refreshed: hub.updated)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !hasChecked {
                    SkeletonList(kind: .reviews)
                } else if lookup.incomplete {
                    Text(L("Some pull request states could not be checked. Those runs remain visible."))
                        .font(UI.metadata).foregroundStyle(Theme.textDim)
                }
                if groups.active.isEmpty, !checking {
                    Text(L("No reviews for open pull requests."))
                        .font(UI.body).foregroundStyle(Theme.textDim)
                        .padding(.vertical, 16)
                }
                if hasChecked {
                    ForEach(groups.active, id: \.key) { status in
                        ReviewRunRow(status: status, local: hub.checkout(of: status.repo), window: window)
                    }
                }
                if !groups.completed.isEmpty {
                    DisclosureGroup(isExpanded: $showCompleted) {
                        ForEach(groups.completed, id: \.key) { status in
                            ReviewRunRow(status: status, local: hub.checkout(of: status.repo), window: window)
                        }
                    } label: {
                        Text(L("Completed · last 30 days") + " (\(groups.completed.count))")
                            .font(UI.metadata).foregroundStyle(Theme.textDim)
                    }
                    .padding(.top, 12)
                }
            }
            .padding(14)
        }
        .task(id: request) {
            checking = true
            let result = await Task.detached(priority: .utility) { ReviewHistory.load(keys: request.keys) }.value
            guard !Task.isCancelled else { return }
            lookup = result
            hasChecked = true
            checking = false
        }
    }
}

private struct ReviewRunRow: View {
    let status: QuorumStatus
    let local: String?
    @ObservedObject var window: WindowModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button { window.openQuorumRun(status) } label: {
                HStack(spacing: 10) {
                    Group {
                        if status.running {
                            ProgressView().controlSize(.small)
                        } else {
                            Icon(status.succeeded ? "checkmark.circle" : (status.isClean && status.outcome == nil ? "circle.dotted" : "xmark.circle"), size: 13)
                                .foregroundStyle(status.succeeded ? Theme.greenTone.strong : (status.outcome == "failed" ? Theme.redTone.strong : Theme.textDim))
                        }
                    }
                    .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text((status.repo.split(separator: "/").last.map(String.init) ?? status.repo) + (status.number.map { " #\($0)" } ?? ""))
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textDim)
                            Badge(text: status.kind == .babysit ? "babysit" : "review")
                            if status.open > 0 {
                                Badge(text: status.open == 1 ? L("1 finding open") : L("%d findings open", status.open), tone: Theme.orange)
                            }
                        }
                        Text(status.title ?? status.summary)
                            .font(UI.control)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if let reason = status.reason, !status.running, !status.succeeded {
                            Text(reason).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(status.summary).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(WorktreeRow.ago(Date().timeIntervalSince(status.date)))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.textFaint)
                    Icon("chevron.right", size: 10).foregroundStyle(Theme.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Every review and fix of this run"))
            HStack(spacing: 4) {
                if let report = status.report {
                    SmallButton(title: L("Report")) { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }
                }
                if let url = status.url {
                    SmallButton(title: "PR", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                }
                if !status.running, let local, let number = status.number {
                    Menu {
                        Button(L("Babysit again")) { again(.babysit, number: number, root: local) }
                        Button(L("Review again")) { again(.review, number: number, root: local) }
                        if let dir = status.runDirectory {
                            Divider()
                            Button(L("Show the run's folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
                        }
                    } label: {
                        Icon("ellipsis", size: 12)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovered ? Theme.fillHover : .clear))
        .onHover { hovered = $0 }
    }

    /// The PR's session when there is one, else a new one in the repository.
    private func again(_ kind: QuorumStatus.Kind, number: Int, root: String) {
        window.showHub = false
        if let workspace = Store.shared.workspaces.first(where: { $0.context.pr == number && $0.context.root == root }) {
            // Its branch made ready first, as for the board's step.
            if kind == .babysit { Landing.shared.review(workspace) } else { QuorumWatch.shared.start(kind, in: workspace) }
            Store.shared.select(workspace)
            return
        }
        let workspace = Store.shared.makeWorkspace(directory: root, in: window)
        window.select(workspace)
        Task.detached(priority: .userInitiated) {
            let live = Git.pullRequest(in: root, number: number)
            await MainActor.run {
                guard case let .found(pull) = live, pull.number == number, pull.state == .open, pull.head != nil
                else {
                    window.show(L("The pull request changed. Refresh and try again."), seconds: 6)
                    return
                }
                Quorum.run(kind, pr: pull.number, draft: pull.isDraft, in: workspace)
                if let first = workspace.sessions.first, workspace.sessions.count > 1 { Store.shared.close(first, in: workspace) }
                QuorumWatch.shared.start(always: true)
            }
        }
    }
}

/// A filter on the board: name and count, filled when chosen.
private struct FilterChip: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text(String(count)).foregroundStyle(selected ? Theme.bg.opacity(0.7) : Theme.textDim)
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(selected ? Theme.bg : Theme.textBody)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.textPrimary : (hovered ? Theme.fillHover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? .clear : Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
