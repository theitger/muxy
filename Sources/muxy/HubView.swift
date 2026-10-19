import SwiftUI

/// The hub (⇧⌘H): all work in one place, from the issue assigned to you to
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
    @AppStorage("hubPage") private var page = "board"

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if page == "worktrees" {
                WorktreesPage(window: window)
            } else {
                board
            }
        }
        .background(Theme.terminal)
        .onAppear {
            hub.refresh()
            if page == "worktrees" { inventory.scan() }
        }
        .onExitCommand { window.showHub = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $page) {
                Text(L("Board")).tag("board")
                Text(L("Worktrees")).tag("worktrees")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
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
        .frame(height: 46)
    }

    @ViewBuilder
    private var account: some View {
        if let login = hub.account.login {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 12))
                Text(login).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Theme.textMuted)
            .help(L("Signed in to GitHub through gh"))
        } else if let problem = hub.account.problem {
            HStack(spacing: 8) {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.orange.strong)
                SmallButton(title: L("Sign in to GitHub"), symbol: "person.crop.circle.badge.plus", prominent: true) {
                    hub.signIn(in: window)
                }
            }
        } else if hub.loading {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Board

    private var board: some View {
        let sessions = store.orderedWorkspaces
        let working = sessions.filter { column(of: $0) == .working }
        let review = sessions.filter { column(of: $0) == .review }
        let ready = sessions.filter { column(of: $0) == .ready }
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                Column(title: L("For you"), count: openIssues.count + hub.reviews.count, symbol: "tray.full") {
                    ForEach(openIssues, id: \.self) { issue in
                        IssueCard(issue: issue, local: hub.checkout(of: issue.repo) != nil) { agents in
                            hub.start(issue, agents: agents, in: window)
                        }
                    }
                    if !hub.reviews.isEmpty {
                        Text(L("Reviews for you"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.top, 6)
                        ForEach(hub.reviews) { request in
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
                Column(title: L("Working"), count: working.count, symbol: "sparkle") {
                    ForEach(working) { SessionCard(workspace: $0, window: window) }
                }
                Column(title: L("In review"), count: review.count, symbol: "eye") {
                    ForEach(review) { SessionCard(workspace: $0, window: window) }
                }
                Column(title: L("Ready to land"), count: ready.count, symbol: "airplane.arrival") {
                    ForEach(ready) { SessionCard(workspace: $0, window: window) }
                }
            }
            .padding(14)
        }
        .scrollIndicators(.never)
    }

    /// Assigned issues no session works on yet.
    private var openIssues: [Issue] {
        hub.issues.filter { hub.session(for: $0) == nil }
            .sorted { ($0.labels.contains("ready-for-agent") ? 0 : 1, $0.number) < ($1.labels.contains("ready-for-agent") ? 0 : 1, $1.number) }
    }

    enum Stage { case working, review, ready, none }

    private func column(of workspace: Workspace) -> Stage {
        let context = workspace.context
        guard context.repo != nil else { return .none }
        if landing.step(for: workspace)?.isActive == true { return .review }
        // Merged or closed: nothing left to do on the board.
        if context.pr != nil, context.prState != .open { return .none }
        guard context.pr != nil else {
            return workspace.agent == .none && workspace.variantGroup == nil && context.branch == nil ? .none : .working
        }
        if workspace.agent == .working || workspace.agent == .blocked { return .working }
        if workspace.prStatus == .ready { return .ready }
        if proofs.result(for: context.checkout)?.verdict == .passed, context.checks == .passed { return .ready }
        return .review
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

private struct Column<Content: View>: View {
    let title: String
    let count: Int
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(String(count)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.textDim)
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
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textPrimary.opacity(0.035)))
    }
}

private struct CardBackground: ViewModifier {
    var highlighted = false
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceActive))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlighted ? Theme.orange.strong.opacity(0.6) : Theme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovered ? 0.08 : 0), radius: 6, y: 2)
            .onHover { hovered = $0 }
    }
}

private struct IssueCard: View {
    let issue: Issue
    let local: Bool
    let start: ([AgentKind]) -> Void
    @AppStorage("newSessionAgent") private var preferred = AgentKind.claude.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(issue.repo.split(separator: "/").last.map(String.init) ?? issue.repo)
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.5).textCase(.uppercase)
                    .foregroundStyle(Theme.textFaint)
                Text("#" + String(issue.number)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim)
                Spacer()
                Button {
                    if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.textDim)
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
                SmallButton(title: L("Start %@", agent.name), symbol: "play.fill", prominent: true) { start([agent]) }
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
                Image(systemName: "arrow.triangle.pull").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textDim)
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
                    SmallButton(title: L("Review with quorum"), symbol: "person.3.fill", action: review)
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

    var body: some View {
        let context = workspace.context
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SessionTile(agent: workspace.agent, attention: workspace.needsAttention, isGit: true, size: 20)
                Text(workspace.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                PRBadge(pr: context.pr, status: workspace.prStatus)
            }
            Text([context.repo, context.branch].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
            Signals(workspace: workspace)
            if let step = landing.step(for: workspace) {
                Text(step.text).font(.system(size: 11.5)).foregroundStyle(Theme.blue.strong).lineLimit(2)
            }
            HStack(spacing: 6) {
                SmallButton(title: L("Open"), symbol: "arrow.right") {
                    window.showHub = false
                    window.select(workspace)
                }
                if context.checkout != nil {
                    SmallButton(title: L("Review"), symbol: "plus.forwardslash.minus") {
                        window.openReview(workspace, scope: .branch)
                    }
                }
                if landing.canLand(workspace), landing.step(for: workspace)?.isActive != true {
                    SmallButton(title: L("Land"), symbol: "airplane.arrival", prominent: true) {
                        landing.land(workspace)
                    }
                }
                if workspace.variantGroup != nil {
                    SmallButton(title: L("Keep this one"), symbol: "star.fill") {
                        FanOut.confirmKeep(workspace)
                    }
                }
            }
        }
        .modifier(CardBackground(highlighted: workspace.agent == .blocked))
        .contentShape(Rectangle())
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
                    Badge(text: L("checking"), tone: Theme.blue, symbol: "shield")
                } else if let proof {
                    switch proof.verdict {
                    case .passed: Badge(text: L("proven"), tone: Theme.greenTone, symbol: "checkmark.shield.fill")
                    case .failed: Badge(text: L("%d checks fail", proof.failed.count), tone: Theme.redTone, symbol: "xmark.shield.fill")
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
                    SmallButton(title: L("quorum gc"), symbol: "trash") {
                        inventory.quorumGC { window.show(L("quorum cleaned its cache")) }
                    }
                    .help(L("quorum's own cleanup for its run folders"))
                }
                if !finished.isEmpty {
                    SmallButton(title: L("Remove %d finished", finished.count), symbol: "sparkles", prominent: true) {
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
                            Text((root as NSString).lastPathComponent)
                                .font(.system(size: 10.5, weight: .semibold)).tracking(0.9).textCase(.uppercase)
                                .foregroundStyle(Theme.textFaint)
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
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
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
                    if hasSession { Badge(text: L("open"), tone: Theme.blue, symbol: "macwindow") }
                    if info.running > 0, let project = info.containers {
                        Badge(text: L("%d containers", info.running), tone: Theme.yellow, symbol: "shippingbox.fill")
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Theme.fillHover : .clear))
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
        var parts: [String] = []
        if info.changes > 0 { parts.append(info.changes == 1 ? L("1 change") : L("%d changes", info.changes)) }
        if info.ahead > 0, info.prState != .merged { parts.append(L("%d unmerged", info.ahead)) }
        if parts.isEmpty { return info.prState == .merged ? L("merged") : L("nothing of its own") }
        return parts.joined(separator: " · ")
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86400)
        if days >= 30 { return L("%dmo", days / 30) }
        if days >= 1 { return L("%dd", days) }
        let hours = Int(seconds / 3600)
        return hours >= 1 ? L("%dh", hours) : L("now")
    }
}
