import SwiftUI

/// The hub (⌘H): all work in one place, from the issue assigned to you to
/// the merged pull request. Columns follow a task through its life; the
/// worktrees page shows every checkout on disk and what can go.
struct HubView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    /// Shown without the sidebar: the window's own buttons sit top left.
    var sidebarFolded = false
    @ObservedObject private var hub = HubModel.shared
    @ObservedObject private var inventory = InventoryModel.shared
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var landing = Landing.shared
    @AppStorage("hubPage") private var page = "board"
    /// Board filters: an organization, a repository (both "" for all), and
    /// only issues an agent can take on its own.
    @AppStorage("hubOrg") private var org = ""
    @AppStorage("hubRepo") private var repo = ""
    @AppStorage("hubReadyOnly") private var readyOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14)
            if page == "board" {
                filterBar
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14)
            }
            if page == "worktrees" {
                WorktreesPage(window: window)
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
        .onExitCommand { window.showHub = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if sidebarFolded {
                Color.clear.frame(width: 66)
                IconButton(symbol: "sidebar.left", help: L("Sidebar (⌘B)")) { store.toggleSidebar() }
            }
            Segments(selection: $page, options: [("board", L("Board")), ("reviews", L("Reviews")), ("worktrees", L("Worktrees"))])
            .onChange(of: page) { if page == "worktrees" { inventory.scan() } }
            Spacer()
            account
            IconButton(symbol: "arrow.clockwise", help: L("Refresh")) {
                hub.refresh()
                radar.scan()
                if page == "worktrees" { inventory.scan() }
            }
            IconButton(symbol: "xmark", help: L("Close hub (esc)")) { window.showHub = false }
        }
        .padding(.horizontal, 14)
        .frame(height: sidebarFolded ? StageMetrics.topBar : 46)
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
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.orange.strong)
                SmallButton(title: L("Sign in to GitHub"), prominent: true) {
                    hub.signIn(in: window)
                }
            }
        } else if hub.loading {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Board

    private var board: some View {
        let sessions = store.orderedWorkspaces.filter(visible)
        let working = sessions.filter { column(of: $0) == .working }
        let review = sessions.filter { column(of: $0) == .review }
        let ready = sessions.filter { column(of: $0) == .ready }
        return GeometryReader { geometry in
        // Four columns share the width: never sideways scrolling.
        // (each column adds 10 pt of padding on either side)
        let width = max(150, (geometry.size.width - 28 - 30) / 4 - 20)
        HStack(alignment: .top, spacing: 10) {
                Column(title: L("For you"), count: openIssues.count + hub.reviews.filter { matches($0.repo) }.count) {
                    let groups = issueGroups
                    ForEach(groups, id: \.repo) { group in
                        // One repository: no heading needed.
                        if groups.count > 1 {
                            HStack(spacing: 6) {
                                SectionLabel(group.repo.split(separator: "/").last.map(String.init) ?? group.repo, tone: Theme.textMuted)
                                Text(String(group.issues.count)).font(Theme.label(size: 11)).foregroundStyle(Theme.textDim)
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                            }
                            .padding(.top, group.repo == groups.first?.repo ? 0 : 8)
                            .help(group.repo)
                        }
                        ForEach(group.issues, id: \.self) { issue in
                            IssueCard(issue: issue, local: hub.checkout(of: issue.repo) != nil, showsRepo: groups.count <= 1) { agents in
                                hub.start(issue, agents: agents, in: window)
                            }
                        }
                    }
                    if !hub.reviews.isEmpty {
                        SectionLabel(L("Reviews for you"))
                            .padding(.top, 6)
                        ForEach(hub.reviews.filter { matches($0.repo) }) { request in
                            ReviewRequestCard(request: request, local: hub.checkout(of: request.repo)) {
                                reviewWithQuorum(request)
                            }
                        }
                    }
                    if openIssues.isEmpty, hub.reviews.isEmpty {
                        Text(hub.loading ? L("Asking GitHub …") : L("Nothing assigned to you."))
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.vertical, 8)
                    }
                }
                Column(title: L("Working"), count: working.count) {
                    ForEach(working) { SessionCard(workspace: $0, window: window) }
                }
                Column(title: L("In review"), count: review.count) {
                    ForEach(review) { SessionCard(workspace: $0, window: window) }
                }
                Column(title: L("Ready to land"), count: ready.count) {
                    ForEach(ready) { SessionCard(workspace: $0, window: window) }
                }
            }
            .environment(\.columnWidth, width)
            .padding(14)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    /// Assigned issues no session works on yet.
    /// Assigned issues no session works on yet, filtered, newest first.
    private var openIssues: [Issue] {
        hub.issues.filter { issue in
            hub.session(for: issue) == nil && matches(issue.repo)
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
        store.runInNewTab(Quorum.command(.review, pr: request.number), in: workspace)
        if let first = workspace.sessions.first, workspace.sessions.count > 1 { store.close(first, in: workspace) }
    }
}

// MARK: Pieces

private struct ColumnWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 300
}

extension EnvironmentValues {
    var columnWidth: CGFloat {
        get { self[ColumnWidthKey.self] }
        set { self[ColumnWidthKey.self] = newValue }
    }
}

private struct Column<Content: View>: View {
    @Environment(\.columnWidth) private var width
    let title: String
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(title, tone: Theme.textMuted)
                Text(String(count)).font(Theme.label(size: 10.5)).foregroundStyle(Theme.textDim)
                Spacer()
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(height: 24)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) { content }
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

private struct CardBackground: ViewModifier {
    var highlighted = false
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surfaceActive))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(highlighted ? Theme.orange.strong.opacity(0.6) : Theme.hairline, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(hovered ? 0.22 : 0), lineWidth: 1)
            )
            .onHover { hovered = $0 }
    }
}

private struct IssueCard: View {
    let issue: Issue
    let local: Bool
    var showsRepo = true
    let start: ([AgentKind]) -> Void
    @AppStorage("newSessionAgent") private var preferred = AgentKind.claude.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if showsRepo {
                    SectionLabel(issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo)
                }
                Text("#" + String(issue.number)).font(Theme.label(size: 10.5)).foregroundStyle(Theme.textDim)
                if let created = issue.created {
                    Text(WorktreeRow.ago(Date().timeIntervalSince(created)))
                        .font(Theme.label(size: 10.5)).foregroundStyle(Theme.textFaint)
                        .help(created.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                Button {
                    if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
                } label: {
                    Icon("arrow.up.right", size: 9.5).foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .help(L("Open on GitHub"))
            }
            Text(issue.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !issue.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(issue.labels.prefix(3), id: \.self) { label in
                        Badge(text: label, tone: label == "ready-for-agent" ? Theme.greenTone : (label.contains("priority") ? Theme.orange : Theme.neutral))
                    }
                }
            }
            HStack(spacing: 6) {
                let agent = AgentKind(rawValue: preferred) ?? .claude
                SmallButton(title: L("Start %@", agent.name), prominent: true) { start([agent]) }
                    .disabled(!local)
                Menu {
                    ForEach(AgentKind.allCases) { kind in
                        Button(L("Start %@", kind.name)) { start([kind]) }
                    }
                    Divider()
                    Button(L("Claude and Codex side by side")) { start(AgentKind.allCases) }
                } label: {
                    Text(L("More")).font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!local)
                Spacer()
                if !local {
                    Text(L("Not cloned here")).font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                }
            }
        }
        .modifier(CardBackground())
    }
}

private struct ReviewRequestCard: View {
    let request: HubModel.ReviewRequest
    let local: String?
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Icon("arrow.triangle.pull", size: 10).foregroundStyle(Theme.textDim)
                Text("#" + String(request.number)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim)
                Text(request.author).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                Spacer()
            }
            Text(request.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if local != nil, Quorum.isInstalled {
                    SmallButton(title: L("Review with quorum"), action: review)
                }
                SmallButton(title: L("Open"), symbol: "arrow.up.right") {
                    if let url = URL(string: request.url) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .modifier(CardBackground())
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
    @State private var message = ""
    @FocusState private var typing: Bool

    var body: some View {
        let context = workspace.context
        let next = Flow.next(for: workspace)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SessionTile(agent: workspace.agent, attention: workspace.needsAttention, isGit: true, kind: workspace.agentTab?.kind, size: 20)
                Text(workspace.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    if let url = workspace.pullRequestURL { NSWorkspace.shared.open(url) }
                } label: {
                    PRBadge(pr: context.pr, status: workspace.prStatus)
                }
                .buttonStyle(.plain)
                .help(L("Open the pull request on GitHub"))
            }
            if let branch = context.branch, branch != workspace.title {
                Text(branch).font(Theme.mono(size: 10.5)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
            }
            Signals(workspace: workspace)
            nextStep(next)
            if workspace.agentTab != nil {
                // Say something to the agent without going there.
                HStack(spacing: 6) {
                    TextField(L("Message the agent …"), text: $message)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($typing)
                        .onSubmit(send)
                    if !message.trimmingCharacters(in: .whitespaces).isEmpty {
                        IconButton(symbol: "paperplane.fill", help: L("Send (↩)"), action: send)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(typing ? Theme.textPrimary.opacity(0.35) : Theme.border, lineWidth: 1)
                )
            }
        }
        .modifier(CardBackground(highlighted: workspace.agent == .blocked))
        .contentShape(Rectangle())
        // The card is the way in: one click and you're in its terminal.
        .onTapGesture(count: 2) { open() }
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
        HStack(spacing: 6) {
            switch next {
            case .wait, .landing:
                ProgressView().controlSize(.mini).frame(width: 12)
                Text(next.title).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
            case .none:
                EmptyView()
            default:
                SmallButton(title: next.title, prominent: true) {
                    if !Flow.take(next, in: workspace, window: window) {
                        window.show(L("No agent runs in this session to ask"))
                    }
                }
            }
            Spacer(minLength: 4)
            SmallButton(title: L("Open")) { open() }
            if context.checkout != nil, next != .answer {
                SmallButton(title: L("Changes")) { window.openReview(workspace, scope: .branch) }
            }
            if workspace.variantGroup != nil {
                SmallButton(title: L("Keep")) { FanOut.confirmKeep(workspace) }
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
        RemoteState.type(text, enter: true, into: agent)
        message = ""
    }
}

/// The small facts under a session: muxy's checks, collisions, quorum.
struct Signals: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var quorum = QuorumWatch.shared

    var body: some View {
        let checkout = workspace.context.checkout
        let collisions = radar.collisions(for: checkout)
        let proof = proofs.result(for: checkout)
        let status = quorum.status(for: workspace)
        if proofs.isRunning(checkout) || proof != nil || !collisions.isEmpty || status != nil {
            FlowSignals {
                if proofs.isRunning(checkout) {
                    Badge(text: L("checking"), tone: Theme.blue)
                } else if let proof {
                    switch proof.verdict {
                    case .passed: Badge(text: L("proven"), tone: Theme.greenTone)
                    case .failed: Badge(text: proof.failed.count == 1 ? L("1 check fails") : L("%d checks fail", proof.failed.count),
                                        tone: Theme.redTone, symbol: "xmark.shield.fill")
                    default: EmptyView()
                    }
                }
                ForEach(Array(collisions.enumerated()), id: \.offset) { _, collision in
                    Badge(text: collision.withBase ? L("conflicts with base") : L("collides: %@", radar.title(of: collision.other)),
                          tone: Theme.orange, symbol: "arrow.triangle.merge")
                        .help(collision.files.joined(separator: "\n"))
                }
                if let status {
                    Badge(text: status.summary, tone: status.running ? Theme.blue : (status.isClean ? Theme.greenTone : Theme.orange),
                          symbol: "person.3.fill")
                }
            }
        }
    }
}

/// Badges left to right, wrapping.
private struct FlowSignals<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { content }
            VStack(alignment: .leading, spacing: 4) { content }
        }
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
                if inventory.scanning {
                    ProgressView().controlSize(.small)
                    Text(L("Looking at every worktree …")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                } else {
                    Text(L("%d worktrees · %d finished", list.filter { $0.owner != .main }.count, finished.count))
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
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
                        .font(.system(size: 12.5, weight: .medium))
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
                .font(.system(size: 11.5))
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

/// Everything quorum did and does: running first, then the newest; each
/// with its findings, its report and the next step.
private struct ReviewsPage: View {
    @ObservedObject var window: WindowModel
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var hub = HubModel.shared

    var body: some View {
        let list = quorum.byKey.values.sorted { ($0.running ? 0 : 1, -$0.date.timeIntervalSince1970) < ($1.running ? 0 : 1, -$1.date.timeIntervalSince1970) }
        if !Quorum.isInstalled {
            VStack(spacing: 10) {
                Text(L("quorum isn't installed.")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textBody)
                Text(L("Settings → Review with quorum installs it.")).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if list.isEmpty {
            Text(L("No reviews yet.")).font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(list.prefix(80), id: \.key) { status in
                        ReviewRunRow(status: status, local: hub.checkout(of: status.repo), window: window)
                    }
                }
                .padding(14)
            }
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
                    Text((status.repo.split(separator: "/").last.map(String.init) ?? status.repo) + " #" + String(status.number ?? 0))
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textDim)
                    Badge(text: status.kind == .babysit ? "babysit" : "review")
                    if status.blockers + status.critical > 0 {
                        Badge(text: L("%d open", status.blockers + status.critical), tone: Theme.orange)
                    }
                }
                Text(status.title ?? status.summary)
                    .font(.system(size: 12.5, weight: .medium))
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
            QuorumWatch.shared.start(kind, in: workspace)
            Store.shared.select(workspace)
            return
        }
        let workspace = Store.shared.makeWorkspace(directory: root, in: window)
        window.select(workspace)
        Store.shared.runInNewTab(Quorum.command(kind, pr: number), in: workspace)
        if let first = workspace.sessions.first, workspace.sessions.count > 1 { Store.shared.close(first, in: workspace) }
        QuorumWatch.shared.start(always: true)
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
