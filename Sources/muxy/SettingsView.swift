import SwiftUI

/// ⌘, — deliberately small: muxy takes its look from your Ghostty config.
struct SettingsView: View {
    @AppStorage(Language.storageKey) private var language = Language.english.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(TerminalColors.storageKey) private var terminalColors = TerminalColors.neutral.rawValue
    @AppStorage(TerminalColors.fontKey) private var fontFamily = ""
    @ObservedObject private var watch = AppearanceWatch.shared
    @AppStorage(TerminalColors.sizeKey) private var fontSize: Double = 0

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Language"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer()
                Picker("", selection: Binding(
                    get: { Language(rawValue: language) ?? .english },
                    set: { Language.select($0) }
                )) {
                    ForEach(Language.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            Text(L("Some menus switch after the next launch."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
            HStack {
                Text(L("Appearance"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer()
                Segments(selection: Binding(
                    get: { AppAppearance(rawValue: appearance) ?? .system },
                    set: { choice in
                        appearance = choice.rawValue
                        AppAppearance.apply(choice)
                    }
                ), options: AppAppearance.allCases.map { ($0, $0.name) })
            }
            .padding(.top, 6)
            HStack {
                Text(L("Terminal colors"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer()
                Segments(selection: Binding(
                    get: { TerminalColors(rawValue: terminalColors) ?? .neutral },
                    set: { choice in
                        terminalColors = choice.rawValue
                        TerminalColors.select(choice)
                    }
                ), options: TerminalColors.allCases.map { ($0, $0.name) })
            }
            HStack {
                Text(L("Terminal font"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Spacer()
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
                .frame(width: 190)
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
                .frame(width: 110)
            }
            Divider().padding(.vertical, 6)
            AgentSettings()
            Divider().padding(.vertical, 6)
            WorkflowSettings()
            Divider().padding(.vertical, 6)
            PromptSettings()
            Divider().padding(.vertical, 6)
            QuorumSettings()
            Divider().padding(.vertical, 6)
            StayAwakeSettings()
            Divider().padding(.vertical, 6)
            QuickTerminalSettings()
            Divider().padding(.vertical, 6)
            RemoteSettings()
            Divider().padding(.vertical, 6)
            CommandLineSettings()
            if Updater.shared.available {
                Divider().padding(.vertical, 6)
                UpdateSettings()
            }
            Divider().padding(.vertical, 6)
            Button(L("Set Up muxy Again…")) { Onboarding.show() }
        }
        .padding(20)
        }
        .frame(width: 460, height: 680)
        .tint(Theme.textPrimary)
        .id(watch.isDark)
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

/// Settings → how "New Session" starts agents, and whether they survive
/// a restart.
private struct AgentSettings: View {
    @AppStorage("skipPermissions") private var skipPermissions = true
    @AppStorage("restoreSessions") private var restoreSessions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HookSettings()
            skip
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Restore sessions"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Text(L("After a quit, a crash or an update, every session comes back: agents with their conversation, shells in their folder."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $restoreSessions)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var skip: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Skip permission prompts"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Text(L("New sessions start Claude with --dangerously-skip-permissions and Codex with --dangerously-bypass-approvals-and-sandbox."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $skipPermissions)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// Settings → what muxy does on its own between the agent's turns.
private struct WorkflowSettings: View {
    @AppStorage(Proofs.autoKey) private var proofAfterTurn = true
    @AppStorage(Landing.quorumKey) private var landWithQuorum = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggle(L("Check after every turn"),
                   L("muxy runs the repository's checks ([check] in .wtconfig) on the agent's work when a turn ends, and tells you when they fail. Checks with auto = false only run on request and when landing."),
                   $proofAfterTurn)
            toggle(L("Land with quorum"),
                   Quorum.isInstalled
                       ? L("Landing hands the pushed pull request to quorum's review loop before it merges.")
                       : L("quorum isn't installed: landing merges once checks pass."),
                   $landWithQuorum)
                .disabled(!Quorum.isInstalled)
        }
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
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
