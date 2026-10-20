import SwiftUI

/// ⌘,: panes on the left, each a short page of cards with one setting
/// per row (what it is on the left, the control on the right). A new
/// setting goes into the pane it belongs to; a new area is a new pane.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, terminal, agents, workflow, review, phone, mac

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: L("General")
            case .terminal: L("Terminal")
            case .agents: L("Agents")
            case .workflow: L("Workflow")
            case .review: L("Review")
            case .phone: L("Phone")
            case .mac: L("This Mac")
            }
        }
    }

    @AppStorage("settingsPane") private var pane = Pane.general.rawValue
    @ObservedObject private var watch = AppearanceWatch.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases) { item in
                    PaneButton(title: item.title, selected: pane == item.rawValue) { pane = item.rawValue }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .frame(width: 180)
            .background(Theme.sidebar)
            Rectangle().fill(Theme.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text((Pane(rawValue: pane) ?? .general).title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    page(Pane(rawValue: pane) ?? .general)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
        }
        .frame(width: 820, height: 580)
        .tint(Theme.textPrimary)
        .id(watch.isDark)
    }

    /// One pane's page on its own (offscreen renders).
    static func page(_ pane: Pane) -> some View {
        VStack(alignment: .leading, spacing: 18) { SettingsView().page(pane) }
    }

    @ViewBuilder
    private func page(_ pane: Pane) -> some View {
        switch pane {
        case .general: GeneralPane()
        case .terminal: TerminalPane()
        case .agents: AgentsPane()
        case .workflow: WorkflowPane()
        case .review: SettingCard { SettingBlock { QuorumSettings() } }
        case .phone: SettingCard { SettingBlock { RemoteSettings() } }
        case .mac: MacPane()
        }
    }
}

private struct PaneButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Theme.fillActive : (hovered ? Theme.fillHover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct GeneralPane: View {
    @AppStorage(Language.storageKey) private var language = Language.english.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        SettingCard {
            SettingRow(L("Language"), detail: L("Some menus switch after the next launch.")) {
                Segments(selection: Binding(
                    get: { Language(rawValue: language) ?? .english },
                    set: { Language.select($0) }
                ), options: Language.allCases.map { ($0, $0.name) })
            }
            SettingRow(L("Appearance"), detail: L("The terminal follows: light or dark colors to match.")) {
                Segments(selection: Binding(
                    get: { AppAppearance(rawValue: appearance) ?? .system },
                    set: { choice in
                        appearance = choice.rawValue
                        AppAppearance.apply(choice)
                    }
                ), options: AppAppearance.allCases.map { ($0, $0.name) })
            }
        }
        if Updater.shared.available {
            SettingCard { SettingBlock { UpdateSettings() } }
        }
        SettingCard {
            SettingRow(L("Setup"), detail: L("Repositories, agents, hooks, notifications: the first-launch walk-through again.")) {
                Button(L("Set Up muxy Again…")) { Onboarding.show() }
            }
        }
    }
}

private struct TerminalPane: View {
    @AppStorage(TerminalColors.storageKey) private var terminalColors = TerminalColors.neutral.rawValue
    @AppStorage(TerminalColors.fontKey) private var fontFamily = ""
    @AppStorage(TerminalColors.sizeKey) private var fontSize: Double = 0

    var body: some View {
        SettingCard {
            SettingRow(L("Colors"), detail: L("muxy's neutral pair, or your Ghostty config's theme.")) {
                Segments(selection: Binding(
                    get: { TerminalColors(rawValue: terminalColors) ?? .neutral },
                    set: { choice in
                        terminalColors = choice.rawValue
                        TerminalColors.select(choice)
                    }
                ), options: TerminalColors.allCases.map { ($0, $0.name) })
            }
            SettingRow(L("Font"), detail: L("Any monospaced font on this Mac, or the one in your Ghostty config.")) {
                Picker("", selection: Binding(get: { fontFamily }, set: { family in
                    fontFamily = family
                    TerminalColors.apply()
                })) {
                    Text(L("From Ghostty")).tag("")
                    Divider()
                    ForEach(TerminalColors.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SettingRow(L("Size")) {
                Picker("", selection: Binding(get: { fontSize }, set: { size in
                    fontSize = size
                    TerminalColors.apply()
                })) {
                    Text(L("Ghostty size")).tag(0.0)
                    Divider()
                    ForEach([10.0, 11, 12, 13, 14, 15, 16, 18, 20], id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
        SettingCard { SettingBlock { QuickTerminalSettings() } }
    }
}

private struct AgentsPane: View {
    @AppStorage("skipPermissions") private var skipPermissions = true
    @AppStorage("restoreSessions") private var restoreSessions = true
    @AppStorage(KeepAlive.key) private var keepSessions = false

    var body: some View {
        SettingCard { SettingBlock { HookSettings() } }
        SettingCard {
            SettingRow(L("Skip permission prompts"), detail: L("New sessions start Claude with --dangerously-skip-permissions and Codex with --dangerously-bypass-approvals-and-sandbox.")) {
                Toggle("", isOn: $skipPermissions).labelsHidden().toggleStyle(.offOn)
            }
            SettingRow(L("Restore sessions"), detail: L("After a quit, a crash or an update, every session comes back: agents with their conversation, shells in their folder.")) {
                Toggle("", isOn: $restoreSessions).labelsHidden().toggleStyle(.offOn)
            }
            SettingRow(L("Sessions keep running when muxy quits (beta)"), detail: KeepAlive.binary == nil
                ? L("This build has no muxyd.")
                : L("New tabs run their program under muxyd, a small background process: quitting, updating or a crash of muxy doesn't stop an agent mid-turn, and the tab finds it again on the next launch. Closing a tab still ends it.")) {
                Toggle("", isOn: $keepSessions).labelsHidden().toggleStyle(.offOn)
                    .disabled(KeepAlive.binary == nil)
            }
        }
        SettingCard { SettingBlock { PromptSettings() } }
        SettingCard { ClaudeLimitsRow() }
    }
}

/// Claude's usage limits in muxy: a script in front of the status line.
private struct ClaudeLimitsRow: View {
    @State private var on = ClaudeStatusTap.isInstalled()
    @State private var problem: String?

    var body: some View {
        SettingRow(L("Claude's limits in muxy"), detail: problem ?? L("Claude Code tells only its status line how much of your plan is used. On: a small script in front of your status line keeps that for muxy and runs your status line as before. Off: your status line as it was. Codex's limits need nothing.")) {
            Toggle("", isOn: Binding(get: { on }, set: { set($0) }))
                .labelsHidden().toggleStyle(.offOn)
                .disabled(!Paths.isApp)
        }
    }

    private func set(_ wanted: Bool) {
        do {
            if wanted { try ClaudeStatusTap.install() } else { try ClaudeStatusTap.uninstall() }
            problem = nil
        } catch {
            problem = (error as? HookInstaller.Failure)?.message ?? error.localizedDescription
        }
        on = ClaudeStatusTap.isInstalled()
    }
}

private struct WorkflowPane: View {
    @AppStorage(Proofs.autoKey) private var proofAfterTurn = true
    @AppStorage(Flow.autoReviewKey) private var reviewWhenPROpens = false
    @AppStorage(Landing.quorumKey) private var landWithQuorum = true
    @AppStorage(Queue.parallelKey) private var queueParallel = Queue.defaultParallel

    var body: some View {
        SettingCard {
            SettingRow(L("Check after every turn"), detail: L("muxy runs the repository's checks ([check] in .wtconfig) on the agent's work when a turn ends, and tells you when they fail. Checks with auto = false only run on request and when landing.")) {
                Toggle("", isOn: $proofAfterTurn).labelsHidden().toggleStyle(.offOn)
            }
            SettingRow(L("Review as soon as a pull request opens"), detail: L("Off: muxy suggests the review and you start it. On: quorum reviews and fixes every new pull request of a session right away.")) {
                Toggle("", isOn: $reviewWhenPROpens).labelsHidden().toggleStyle(.offOn)
                    .disabled(!Quorum.isInstalled)
            }
            SettingRow(L("Land with quorum"), detail: Quorum.isInstalled
                ? L("Landing hands the pushed pull request to quorum's review loop before it merges, unless quorum already passed it.")
                : L("quorum isn't installed: landing merges once checks pass.")) {
                Toggle("", isOn: $landWithQuorum).labelsHidden().toggleStyle(.offOn)
                    .disabled(!Quorum.isInstalled)
            }
        }
        SettingCard(L("Queue")) {
            SettingRow(L("At a time"), detail: L("How many queued issues run at once. Each is an agent in its own worktree without permission prompts, then checks, a pull request and quorum's fix loop, up to ready to land. More at once uses up your plans faster.")) {
                Segments(selection: $queueParallel, options: [1, 2, 3, 4, 5].map { ($0, String($0)) })
            }
        }
    }
}

private struct MacPane: View {
    var body: some View {
        SettingCard { SettingBlock { StayAwakeSettings() } }
        SettingCard { SettingBlock { CommandLineSettings() } }
    }
}

/// Settings → keep the Mac awake: not, while open (like caffeinate), or
/// lid closed too. The same control in the setup.
struct StayAwakeSettings: View {
    @ObservedObject private var awake = StayAwake.shared
    var titleColor = Theme.textBody

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Keep the Mac awake"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(titleColor)
            Picker(L("Keep the Mac awake"), selection: Binding(get: { awake.mode }, set: { awake.setMode($0) })) {
                Text(L("Off")).tag(StayAwake.Mode.off)
                Text(L("While open")).tag(StayAwake.Mode.open)
                Text(L("Lid closed too")).tag(StayAwake.Mode.lidClosed)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            Text(explanation)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = awake.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.red)
            } else if awake.mode != .off, awake.lowBattery {
                Text(L("Paused: battery below %d %%, the Mac may sleep.", StayAwake.batteryFloor))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
            } else if awake.holding {
                Text(L("On: the Mac won't sleep, lid closed included. Mind the heat in a bag."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.green)
            } else if awake.caffeinated {
                Text(L("On: the Mac stays awake while it is open."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.green)
            }
        }
    }

    private var explanation: String {
        switch awake.mode {
        case .off: L("The Mac sleeps as usual, and agents pause with it.")
        case .open: L("Like caffeinate: no sleep while Muxy runs and the Mac is open. The display may still turn off. No password needed.")
        case .lidClosed: L("While Muxy runs, even with the lid closed. Asks for your password once.")
        }
    }
}

/// Settings → what an agent is told when it starts on an issue.
private struct PromptSettings: View {
    @AppStorage(Issues.templateKey) private var template = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Prompt for issues"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer()
                if !template.isEmpty, template != Issues.defaultTemplate {
                    Button(L("Back to the default")) { template = "" }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                }
            }
            Text(L("What the agent gets when you start it on an issue. Fields in braces are filled in; an empty one leaves no gap."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(
                get: { template.isEmpty ? Issues.defaultTemplate : template },
                set: { template = $0 == Issues.defaultTemplate ? "" : $0 }
            ))
            .font(Theme.mono(size: 11.5))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fillHover))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            Text(Issues.templateFields.joined(separator: "  "))
                .font(Theme.mono(size: 10.5))
                .foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
        }
    }
}
