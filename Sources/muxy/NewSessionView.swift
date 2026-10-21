import SwiftUI
import AppKit

/// ⌘N: a session starts with what should happen. Task, repository, agent
/// and, by default, its own worktree and branch; one sentence beside the
/// button says exactly what Start will do. ⌘1…6 picks a repository, ⇥ the
/// agent, ↩ starts. The task can be a GitHub issue ("#123", its URL): the
/// agent then gets the issue and the branch its number (see IssueField).
struct NewSessionView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel

    @State private var agentChoice = AgentKind.preferredChoice()
    @AppStorage("newSessionWorktree") private var useWorktree = true
    @State private var prompt = ""
    @State private var repos: [Repos.Repo] = []
    @State private var reposLoading = true
    @State private var directory: String?
    @State private var branch = ""
    @StateObject private var issues = IssueField()
    @State private var waitingToStart = false
    @FocusState private var focused: Bool

    init(store: Store, window: WindowModel, repos: [Repos.Repo] = []) {
        self.store = store
        self.window = window
        _repos = State(initialValue: repos)
        _directory = State(initialValue: repos.first?.path)
    }

    /// Repositories offered as chips; the rest sit behind "Other".
    private static let chipCount = 6

    /// The fan-out choice: Claude and Codex side by side.
    static let both = "both"
    private var fanOut: Bool { agentChoice == Self.both }
    /// nil: a plain shell. Fan-out names Claude here (its first variant).
    private var agent: AgentKind? { fanOut ? .claude : AgentKind(rawValue: agentChoice) }
    private var target: String { directory ?? Paths.home }
    /// The repository the chosen folder belongs to.
    private var repo: Repos.Repo? {
        repos.filter { target.hasPrefix($0.path) }.max { $0.path.count < $1.path.count }
    }
    private var worktree: Bool { repo != nil && useWorktree }
    /// A branch you typed; otherwise Start picks a placeholder that is
    /// renamed after the task once the session runs (see BranchNamer).
    private var typedBranch: String? {
        let typed = branch.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? nil : typed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 18) {
                if agent != nil {
                    section(L("Task"), keys: "#") {
                        taskField
                        IssueAccessory(field: issues, place: repo?.name ?? Paths.folderName(target), pick: pick)
                    }
                }
                section(L("Repository"), keys: "⌘1–6") { repoRow }
                section(L("Agent"), keys: "⇥") { agentRow }
                if repo != nil { worktreeRow }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)

            footer
        }
        .frame(width: 600)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(shortcuts)
        .onAppear(perform: prepare)
        .onChange(of: repo?.path, initial: true) { _, path in
            if let path { Launcher.prefetch(path, spare: useWorktree) }
        }
        .onChange(of: [prompt, target, repo?.path ?? ""], initial: true) {
            issues.update(text: prompt, directory: target, root: repo?.path)
        }
        .onChange(of: repos, initial: true) { issues.learn(repos) }
        // ↩ while the issue was still being looked up: start once it's in.
        .onChange(of: issues.status) {
            if waitingToStart, !issues.isLoading {
                waitingToStart = false
                start()
            }
        }
        .onChange(of: issues.matchedRepo) { _, path in
            if let path { select(path) }
        }
        .onExitCommand { window.showNewSession = false }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Text(L("New session"))
                .font(UI.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { window.showNewSession = false } label: {
                HStack(spacing: 6) {
                    Text(L("Cancel")).font(.system(size: 12))
                    Kbd("esc")
                }
                .foregroundStyle(Theme.textDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func section<Content: View>(
        _ title: String, keys: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                if let keys {
                    Text(keys)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            content()
        }
    }

    private var taskField: some View {
        TextField(L("What should the agent do? Or #123 for an issue"), text: $prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(2 ... 6)
            .focused($focused)
            .onSubmit(start)
            .onKeyPress(.tab) {
                cycleAgent()
                return .handled
            }
            // The issue list after a "#": ↑↓ walk it, ↩ takes one.
            .onKeyPress(.upArrow) { issues.move(-1) ? .handled : .ignored }
            .onKeyPress(.downArrow) { issues.move(1) ? .handled : .ignored }
            .onKeyPress(.return) {
                guard let issue = issues.highlighted else { return .ignored }
                pick(issue)
                return .handled
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(field(active: focused))
    }

    @ViewBuilder private var repoRow: some View {
        if reposLoading, repos.isEmpty {
            SkeletonGroup {
                FlowRow(spacing: 6) {
                    ForEach([120.0, 105, 135, 100, 115, 95], id: \.self) { SkeletonBar(width: $0, height: 30, radius: 7) }
                }
            }
        } else {
            FlowRow(spacing: 6) {
                ForEach(Array(repos.prefix(Self.chipCount).enumerated()), id: \.element.id) { index, repo in
                    Chip(selected: target == repo.path, help: Paths.abbreviate(repo.path)) {
                        select(repo.path)
                    } label: {
                        HStack(spacing: 6) {
                            Text(repo.name).lineLimit(1)
                            Text("⌘\(index + 1)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                Menu {
                    ForEach(repos.dropFirst(Self.chipCount)) { repo in
                        Button(repo.name) { select(repo.path) }
                    }
                    if repos.count > Self.chipCount { Divider() }
                    Button(L("Choose Folder…"), action: chooseFolder)
                } label: {
                    Text(chosenElsewhere ?? L("Other …"))
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(chosenElsewhere != nil ? Theme.fillActive : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(chosenElsewhere != nil ? Theme.textPrimary.opacity(0.3) : Theme.hairline, lineWidth: 1)
                )
            }
        }
    }

    /// The folder's name when it isn't one of the chips.
    private var chosenElsewhere: String? {
        guard let directory, !repos.prefix(Self.chipCount).contains(where: { $0.path == directory }) else { return nil }
        return Paths.folderName(directory)
    }

    private var agentRow: some View {
        HStack(spacing: 6) {
            ForEach([AgentKind.claude.rawValue, AgentKind.codex.rawValue, Self.both, "shell"], id: \.self) { choice in
                let kind = AgentKind(rawValue: choice)
                Chip(selected: agentChoice == choice, help: choice == Self.both
                     ? L("Both agents on the same task, each in its own worktree: keep the better one") : "⇥") {
                    agentChoice = choice
                } label: {
                    HStack(spacing: 7) {
                        if choice == Self.both {
                            HStack(spacing: 2) {
                                AgentGlyph(kind: .claude, size: 12)
                                AgentGlyph(kind: .codex, size: 12)
                            }
                            Text(L("Both"))
                        } else {
                            AgentGlyph(kind: kind, size: 13)
                            Text(kind?.name ?? L("Terminal only"))
                        }
                    }
                }
            }
        }
    }

    private var worktreeRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $useWorktree) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Own worktree"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(L("A separate checkout on a new branch, so sessions don't collide."))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.offOn)
            .controlSize(.small)
            Spacer(minLength: 8)
            if worktree {
                HStack(spacing: 6) {
                    Icon("arrow.triangle.branch", size: 10.5)
                        .foregroundStyle(Theme.textDim)
                    TextField(L("Name: automatic"), text: $branch)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(size: 12))
                        .foregroundStyle(Theme.textBody)
                        .onSubmit(start)
                }
                .padding(.horizontal, 10)
                .frame(width: 210, height: 30)
                .background(field(active: false))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(summary)
                .foregroundStyle(Theme.textMuted)
                .font(.system(size: 12))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: start) {
                HStack(spacing: 8) {
                    Text(fanOut ? L("Start both") : agent.map { L("Start %@", $0.name) } ?? L("Open"))
                    Text("↩").opacity(0.6)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.textPrimary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.textPrimary.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// The issue the task names, once found.
    private var issue: Issue? { agent == nil ? nil : issues.resolved?.issue }
    /// An issue names its own branch.
    private var issueBranch: String? { issue.map(Issues.branchName) }

    /// What Start will do, in one sentence.
    private var summary: String {
        let place = repo?.name ?? Paths.folderName(target)
        var text: String
        switch (agent, worktree) {
        case let (agent?, true) where issue != nil:
            text = L("%@ works on #%d in %@ on the new branch %@.",
                     agent.name, issue?.number ?? 0, place, typedBranch ?? issueBranch ?? "")
        case let (agent?, false) where issue != nil:
            text = L("%@ works on #%d directly in %@.", agent.name, issue?.number ?? 0, Paths.abbreviate(target))
        case let (agent?, true):
            text = typedBranch.map { L("%@ starts in %@ on the new branch %@.", agent.name, place, $0) }
                ?? L("%@ starts in %@ on a new branch, named after the task.", agent.name, place)
        case let (agent?, false):
            text = L("%@ starts directly in %@.", agent.name, Paths.abbreviate(target))
        case (nil, true):
            text = typedBranch.map { L("A terminal opens in %@ on the new branch %@.", place, $0) }
                ?? L("A terminal opens in %@ on a new branch.", place)
        case (nil, false):
            text = L("A terminal opens in %@.", Paths.abbreviate(target))
        }
        if fanOut {
            text = repo == nil
                ? L("Side by side needs a repository.")
                : L("Claude and Codex each work on it in their own worktree in %@. Keep the better one.", place)
        }
        if agent != nil, store.skipPermissions { text += " " + L("No permission prompts.") }
        return text
    }

    private func field(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.textPrimary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(active ? Theme.textPrimary.opacity(0.28) : Theme.hairline, lineWidth: 1)
            )
    }

    /// ⌘1…6: invisible buttons carry the repository shortcuts.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(repos.prefix(Self.chipCount).enumerated()), id: \.element.id) { index, repo in
                Button("") { select(repo.path) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: Actions

    /// Starts in the repository of the session in front, never in home
    /// when there is any repository to offer.
    private func prepare() {
        focused = true
        let current = window.newTaskDirectory ?? window.selectedWorkspace?.context.root
        let open = ([current] + store.orderedWorkspaces.map(\.context.root)).compactMap { $0 }
        if let current { directory = current }
        Task.detached(priority: .userInitiated) {
            let found = Repos.load(open: open)
            await MainActor.run {
                repos = found
                reposLoading = false
                if directory == nil { directory = found.first?.path }
            }
        }
    }

    /// An issue from the list: the field names it, the lookup fills in the rest.
    private func pick(_ issue: Issue) {
        prompt = "#\(issue.number)"
        focused = true
    }

    private func select(_ path: String) {
        directory = path
        focused = true
    }

    private func cycleAgent() {
        let order = AgentKind.allCases.map(\.rawValue) + [Self.both, "shell"]
        let index = order.firstIndex(of: agentChoice) ?? 0
        agentChoice = order[(index + 1) % order.count]
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: target)
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !repos.contains(where: { $0.path == path }), Launcher.mainCheckout(of: path) == path {
                repos.append(Repos.Repo(path: path))
            }
            select(path)
        }
    }

    private func start() {
        if agent == nil {
            store.launch(SessionSpec(directory: target, agent: nil, prompt: "",
                                     worktree: worktree, branch: typedBranch), in: window)
            window.newTaskDirectory = nil
            window.showNewSession = false
            return
        }
        if issues.isLoading {
            waitingToStart = true
            return
        }
        let resolved = issues.resolved
        if fanOut, let root = repo?.path {
            if let resolved {
                FanOut.launch(issue: resolved.issue, root: root, agents: AgentKind.allCases, in: window)
            } else if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FanOut.launch(prompt: prompt, root: root, agents: AgentKind.allCases, in: window)
            } else {
                return
            }
            window.showNewSession = false
            return
        }
        var spec = SessionSpec(
            directory: target, agent: agent,
            prompt: resolved.map {
                Self.issuePrompt(for: $0.issue, note: $0.note, localRepo: issues.targetRepo,
                                 agent: agent, implement: Issues.implementSkill(in: target),
                                 instructions: TaskLedger.shared.instructions(for: $0.issue), root: repo?.path ?? target)
            } ?? ImplementationWorkflow.applying(to: prompt, agent: agent, root: repo?.path),
            worktree: worktree, branch: typedBranch ?? issueBranch
        )
        // An issue already named it.
        if resolved != nil { spec.autoName = false }
        spec.issue = resolved?.issue
        store.launch(spec, in: window)
        window.newTaskDirectory = nil
        window.showNewSession = false
    }

    static func issuePrompt(for issue: Issue, note: String, localRepo: String?, agent: AgentKind?,
                            implement: Bool, instructions: String, root: String? = nil) -> String {
        let prompt = if let root {
            ImplementationWorkflow.prompt(for: issue, note: note, localRepo: localRepo, agent: agent, root: root)
        } else {
            Issues.prompt(for: issue, note: note, localRepo: localRepo, agent: agent, implement: implement)
        }
        return [prompt, instructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// A choice in the ⌘N panel: outlined, filled and darker-edged when chosen.
private struct Chip<Label: View>: View {
    let selected: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Theme.fillActive : (hovered ? Theme.fillHover : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Theme.textPrimary.opacity(0.3) : Theme.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
    }
}
