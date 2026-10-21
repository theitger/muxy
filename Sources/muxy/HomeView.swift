import SwiftUI

/// Start is useful both with no sessions and with a whole day of work open.
/// It does not create a PTY or start an agent until the user chooses work.
struct HomeView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject private var work = WorkLedger.shared
    @ObservedObject private var hub = HubModel.shared
    @ObservedObject private var queue = Queue.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var acceptance = Acceptance.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @State private var repos: [Repos.Repo] = []
    @State private var reposLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        heading
                        Spacer(minLength: 16)
                        startActions
                    }
                    VStack(alignment: .leading, spacing: 20) { heading; startActions }
                }
                if store.orderedWorkspaces.isEmpty, work.withoutSession.isEmpty { welcome }
                decisions
                AgentUpdates(store: store)
                activeWork
                savedWork
                repositories
            }
            .padding(UI.pageInset)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task {
            let open = store.orderedWorkspaces.compactMap(\.context.root)
            let found = await Task.detached(priority: .utility) { Repos.load(open: open) }.value
            guard !Task.isCancelled else { return }
            repos = found
            reposLoading = false
        }
    }

    private var heading: some View {
        PageHeading(title: L("Your workspace"), subtitle: L("Pick up your work, make a decision, or start something new."))
    }

    private var startActions: some View {
        HStack(spacing: 8) {
            ActionButton(title: L("Open terminal"), symbol: "terminal") { window.newWorkspace() }
            ActionButton(title: L("New session"), symbol: "plus", primary: true) { window.newTask() }
        }
    }

    private var welcome: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(Array([("1", L("Start with a goal"), L("Choose a repository and an agent. An issue is optional.")),
                           ("2", L("Work in context"), L("Terminal, preview and changes stay with the task.")),
                           ("3", L("Inspect and finish"), L("Try the result, give feedback, then land when ready."))].enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.0).font(UI.metadata).foregroundStyle(Theme.textMuted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.fillActive))
                    Text(step.1).font(UI.heading).foregroundStyle(Theme.textPrimary)
                    Text(step.2).font(UI.metadata).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: UI.radius).fill(Theme.sidebar))
    }

    @ViewBuilder private var decisions: some View {
        let values = TaskDecision.items()
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(L("Needs you"), count: values.count)
                VStack(spacing: 0) {
                    ForEach(values.prefix(4)) { value in
                        Button { window.openTask(value.target, section: value.action == L("Inspect and accept") ? "implementation" : "overview") } label: {
                            HStack(spacing: 14) {
                                Circle().fill(Theme.orange.strong).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(value.target.title).font(UI.heading).foregroundStyle(Theme.textPrimary).lineLimit(2)
                                    Text(value.reason).font(UI.metadata).foregroundStyle(Theme.textMuted).lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Icon("arrow.right", size: 15).foregroundStyle(Theme.textMuted)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if value.id != values.prefix(4).last?.id { Divider().padding(.horizontal, 16) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: UI.radius).fill(Theme.orange.soft))
                if values.count > 4 {
                    Button(L("See all decisions")) { window.openLibrary("attention") }.buttonStyle(.plain).font(UI.control)
                }
            }
        }
    }

    private var activeWork: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(L("Continue working"), count: store.orderedWorkspaces.count)
            if store.orderedWorkspaces.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("A clear place to start.")).font(UI.heading).foregroundStyle(Theme.textPrimary)
                    Text(L("Describe a task or open a terminal. Your work will appear here."))
                        .font(UI.body).foregroundStyle(Theme.textMuted)
                    Button(L("Create your first task")) { window.newTask() }
                        .buttonStyle(.plain).font(UI.control).foregroundStyle(Theme.textPrimary).padding(.top, 4)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Theme.border))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(store.orderedWorkspaces) { workspace in
                        HomeWorkCard(workspace: workspace) {
                            store.window(of: workspace)?.select(workspace)
                            store.window(of: workspace)?.bringToFront()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var savedWork: some View {
        if work.withoutSession.isEmpty, hub.awaitingFirstResponse {
            SkeletonSavedWork()
        } else if !work.withoutSession.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(L("Without an open session"), count: work.withoutSession.count)
                Text(L("Open branches and pull requests from your repositories. No terminal session is running for these tasks."))
                    .font(UI.metadata).foregroundStyle(Theme.textMuted)
                ForEach(work.withoutSession.prefix(6)) { item in
                    Button { window.openTask(TaskTarget(work: item)) } label: {
                        HStack(spacing: 12) {
                            Icon("arrow.triangle.branch", size: 16)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(UI.body).foregroundStyle(Theme.textPrimary)
                                Text((item.repo ?? Paths.folderName(item.root)) + " · " + item.branch)
                                    .font(UI.metadata).foregroundStyle(Theme.textMuted).lineLimit(1)
                                Text(item.pr.map { L("Open pull request #%d", $0) }
                                     ?? (item.conversation != nil ? L("Previous agent conversation") : L("Local branch")))
                                    .font(UI.metadata).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Text(L("Open task")).font(UI.control)
                        }.padding(14).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L("Start in a repository")).font(UI.heading).foregroundStyle(Theme.textPrimary)
                if reposLoading { SkeletonGroup { SkeletonBar(width: 18, height: 12) } }
                else { Text(String(repos.count)).font(UI.metadata).foregroundStyle(Theme.textMuted) }
                Spacer()
            }
            if reposLoading, repos.isEmpty {
                SkeletonRepositoryGrid()
            } else if repos.isEmpty {
                Text(L("Choose a folder when creating a task, or add repository folders in Settings."))
                    .font(UI.body).foregroundStyle(Theme.textMuted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(repos.prefix(9)) { repo in
                    Button { window.newTask(in: repo.path) } label: {
                        HStack(spacing: 10) {
                            Icon("folder", size: 17).foregroundStyle(Theme.textMuted)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(repo.name).font(UI.control).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Text(Paths.abbreviate(repo.path)).font(UI.metadata).foregroundStyle(Theme.textMuted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .background(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Theme.border))
                }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(UI.heading).foregroundStyle(Theme.textPrimary)
            Text(String(count)).font(UI.metadata).foregroundStyle(Theme.textMuted)
            Spacer()
        }
    }
}

private struct HomeWorkCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var results = Results.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var acceptance = Acceptance.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    AgentGlyph(kind: workspace.featured?.kind, size: 18)
                    Text(workspace.context.repo ?? L("Terminal")).font(UI.metadata).foregroundStyle(Theme.textMuted)
                    Spacer()
                    PRBadge(pr: workspace.context.pr, status: workspace.prStatus)
                }
                Text(workspace.title).font(UI.heading).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                HStack(spacing: 7) {
                    Circle().fill(Theme.tone(for: workspace.agent).strong).frame(width: 6, height: 6)
                    Text(status).font(UI.control).foregroundStyle(Theme.textBody).lineLimit(1)
                    Spacer(minLength: 0)
                    Icon("arrow.right", size: 13).foregroundStyle(Theme.textMuted)
                }
            }.padding(18).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: UI.radius).fill(hovered ? Theme.fillHover : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Theme.border))
            .onHover { hovered = $0 }
    }

    private var status: String {
        workspace.visibleStatus.text
    }
}
