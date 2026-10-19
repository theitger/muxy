import AppKit
import SwiftUI
import UserNotifications

/// The first launch: five short steps that leave muxy ready to work.
/// Repositories, agents, hooks, notifications, keeping the Mac awake.
/// Shown once; Settings and the Help menu open it again.
@MainActor
enum Onboarding {
    static let doneKey = "onboardingDone"
    private static var window: NSWindow?

    /// Once for the app; never for the dev build, whose launches would
    /// keep interrupting work, unless MUXY_ONBOARDING=1 asks for it.
    static var isDue: Bool {
        if ProcessInfo.processInfo.environment["MUXY_ONBOARDING"] == "1" { return true }
        guard Paths.isApp else { return false }
        return !UserDefaults.standard.bool(forKey: doneKey)
    }

    static func showIfDue() {
        guard isDue else { return }
        // After the first main window, so the setup lands in front of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { show() }
    }

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: OnboardingView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("Set up muxy")
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Theme.surface)
        window.contentView = NSHostingView(rootView: OnboardingView { finish() })
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { finish(closing: false) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Done or skipped: either way it doesn't come back by itself.
    private static func finish(closing: Bool = true) {
        UserDefaults.standard.set(true, forKey: doneKey)
        // Skipped before the notifications step: macOS asks on its own.
        Notifier.requestPermission()
        guard let window else { return }
        self.window = nil
        if closing { window.close() }
    }
}

struct OnboardingView: View {
    static let width: CGFloat = 580
    static let height: CGFloat = 540

    var close: () -> Void
    @State private var step: Step

    init(from step: Step = .repositories, close: @escaping () -> Void) {
        self.close = close
        _step = State(initialValue: step)
    }

    enum Step: Int, CaseIterable {
        case repositories, agents, hooks, notifications, awake
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch step {
                case .repositories: RepositoriesStep()
                case .agents: AgentsStep()
                case .hooks: HooksStep()
                case .notifications: NotificationsStep()
                case .awake: AwakeStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 18)
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Theme.surface)
        .onAppear { AgentSetup.shared.refresh() }
    }

    private var title: String {
        switch step {
        case .repositories: L("Where do your repositories live?")
        case .agents: L("Which agents do you use?")
        case .hooks: L("Let muxy see what your agents do")
        case .notifications: L("Hear when a session needs you")
        case .awake: L("Keep agents working while you're away")
        }
    }

    private var subtitle: String {
        switch step {
        case .repositories: L("New sessions offer the repositories in these folders.")
        case .agents: L("muxy starts them for you. Choose the one ⌘N picks first.")
        case .hooks: L("A small hook tells muxy when an agent is working, done or waiting for you.")
        case .notifications: L("A banner when an agent is done or waiting, while you're in another app.")
        case .awake: L("Optional. You can change all of this later in Settings.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Theme.textPrimary.opacity(0.7) : Theme.textPrimary.opacity(0.12))
                        .frame(width: item == step ? 22 : 8, height: 4)
                }
                Spacer()
                Text(L("Step %d of %d", step.rawValue + 1, Step.allCases.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Step %d of %d", step.rawValue + 1, Step.allCases.count))
            VStack(alignment: .leading, spacing: 5) {
                if step == .repositories {
                    Text(L("Welcome to muxy"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .animation(Theme.ease, value: step)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(L("Skip setup"), action: close)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .keyboardShortcut(.cancelAction)
                .opacity(step == .awake ? 0 : 1)
            Spacer()
            if step != .repositories {
                Button(L("Back")) { move(-1) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            Button {
                if step == .awake { close() } else { move(1) }
            } label: {
                HStack(spacing: 8) {
                    Text(step == .awake ? L("Done") : L("Continue"))
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
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Theme.textPrimary.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func move(_ offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        withAnimation(Theme.ease) { step = next }
    }
}

// MARK: - Steps

/// Folders with repositories in them, found under home; the chosen ones
/// are what Repos scans from now on.
private struct RepositoriesStep: View {
    struct Folder: Identifiable, Equatable {
        let path: String
        var count: Int
        var id: String { path }
    }

    @State private var folders: [Folder] = []
    @State private var chosen = Set<String>()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if folders.isEmpty {
                Text(L("No repositories found in your home folder. Add the folder you keep them in."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(folders) { folder in
                        OnboardingRow(selected: chosen.contains(folder.path)) {
                            toggle(folder.path)
                        } content: {
                            Icon("folder", size: 12)
                                .foregroundStyle(Theme.textMuted)
                            Text(Paths.abbreviate(folder.path))
                                .font(Theme.mono(size: 12.5))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(folder.count == 1 ? L("1 repository") : L("%d repositories", folder.count))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textDim)
                        }
                    }
                }
            }
            .frame(maxHeight: 230)
            .fixedSize(horizontal: false, vertical: true)
            Button(L("Add Folder…"), action: addFolder)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        let saved = UserDefaults.standard.stringArray(forKey: Repos.foldersKey)
        Task.detached(priority: .userInitiated) {
            // Grouped by the folder they sit in; your choices from before
            // stay listed even when nothing is in them right now.
            var counts: [String: Int] = [:]
            for (path, _) in Repos.scan(in: [Paths.home] + (saved ?? [])) {
                counts[(path as NSString).deletingLastPathComponent, default: 0] += 1
            }
            for path in saved ?? [] where counts[path] == nil { counts[path] = 0 }
            let found = counts.map { Folder(path: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.path) > ($1.count, $0.path) }
            await MainActor.run {
                folders = found
                chosen = Set(saved ?? found.map(\.path))
                loaded = true
                save()
            }
        }
    }

    private func toggle(_ path: String) {
        if chosen.contains(path) { chosen.remove(path) } else { chosen.insert(path) }
        save()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: Paths.home)
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        if !folders.contains(where: { $0.path == path }) {
            let count = Repos.scan(in: [path]).count
            folders.append(Folder(path: path, count: count))
        }
        chosen.insert(path)
        save()
    }

    /// In the order shown; none chosen means home, as before.
    private func save() {
        Repos.folders = folders.map(\.path).filter(chosen.contains)
    }
}

/// Claude and Codex as your login shell finds them, and the default.
private struct AgentsStep: View {
    @ObservedObject private var setup = AgentSetup.shared
    @AppStorage("newSessionAgent") private var agentChoice = AgentKind.claude.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 6) {
                ForEach(AgentKind.allCases) { kind in
                    let agent = setup.agent(kind)
                    OnboardingRow(selected: agentChoice == kind.rawValue) {
                        agentChoice = kind.rawValue
                    } content: {
                        AgentGlyph(kind: kind, size: 15)
                        Text(kind.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        if !setup.checked {
                            ProgressView().controlSize(.mini)
                        } else if let path = agent?.path {
                            Text(Paths.abbreviate(path))
                                .font(Theme.mono(size: 11.5))
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(L("Not installed on this Mac"))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                        if agentChoice == kind.rawValue {
                            Text(L("Default"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .accessibilityHint(L("Makes it the default agent"))
                }
                OnboardingRow(selected: AgentKind(rawValue: agentChoice) == nil) {
                    agentChoice = "shell"
                } content: {
                    AgentGlyph(kind: nil, size: 15)
                    Text(L("Terminal only"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if AgentKind(rawValue: agentChoice) == nil {
                        Text(L("Default"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            if setup.checked, setup.agents.allSatisfy({ $0.path == nil }) {
                Text(L("Neither Claude Code nor Codex was found. Install one, then come back here from Settings."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange.strong)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: setup.checked, initial: true) { _, checked in
            // The default should be an agent you actually have.
            guard checked, let kind = AgentKind(rawValue: agentChoice), setup.agent(kind)?.path == nil,
                  let other = setup.agents.first(where: { $0.path != nil }) else { return }
            agentChoice = other.kind.rawValue
        }
    }
}

/// What installing the hooks writes, and the button that does it.
private struct HooksStep: View {
    @ObservedObject private var setup = AgentSetup.shared

    private var found: [AgentSetup.Agent] { setup.agents.filter { $0.path != nil } }
    private var pending: [AgentKind] {
        found.filter { $0.hooks == .notInstalled || $0.hooks == .outdated }.map(\.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Installing writes:"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                written(Paths.abbreviate(AgentSetup.scriptURL.path), L("the hook script, shared by both agents"))
                ForEach(found, id: \.kind) { agent in
                    written(
                        Paths.abbreviate(agent.settings.path),
                        L("%d entries for %@. Everything else in it stays as it is.",
                          agent.kind == .claude ? HookInstaller.claudeHooks.count : HookInstaller.codexHooks.count,
                          agent.kind.name)
                    )
                }
                Text(L("Outside muxy the hook does nothing. muxy keeps it up to date after updates."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.textPrimary.opacity(0.04))
            )

            if setup.checked {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(found, id: \.kind) { HookRow(agent: $0, showsAction: false) }
                }
                if !pending.isEmpty {
                    Button(L("Install hooks")) { setup.install(pending) }
                        .controlSize(.large)
                        .disabled(setup.busy)
                } else if found.isEmpty {
                    Text(L("No agent found, nothing to install yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func written(_ path: String, _ what: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(path)
                .font(Theme.mono(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Text(what)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// macOS asks once; after a "Don't Allow" only System Settings can change it.
private struct NotificationsStep: View {
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !Notifier.available {
                Text(L("Only Muxy.app can show notifications, this build can't."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textDim)
            } else {
                switch status {
                case .authorized?, .provisional?:
                    Label { Text(L("Notifications are on.")) } icon: { Icon("checkmark.circle.fill", size: 12) }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.green)
                case .denied?:
                    Text(L("Notifications are off for muxy."))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Button(L("Open System Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.large)
                default:
                    Button(L("Allow Notifications")) {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                            Task { @MainActor in refresh() }
                        }
                    }
                    .controlSize(.large)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        guard Notifier.available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let value = settings.authorizationStatus
            Task { @MainActor in status = value }
        }
    }
}

/// The same control as in Settings.
private struct AwakeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StayAwakeSettings(titleColor: Theme.textPrimary)
            Text(L("Below %d %% battery the Mac may sleep again.", StayAwake.batteryFloor))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
        }
    }
}

/// A choice in the setup: outlined, filled when chosen, like ⌘N's chips.
private struct OnboardingRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(selected ? "checkmark.circle.fill" : "circle", size: 13)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textFaint)
                content
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
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
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
