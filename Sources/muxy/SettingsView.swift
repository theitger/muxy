import SwiftUI

/// ⌘, — deliberately small: muxy takes its look from your Ghostty config.
struct SettingsView: View {
    @AppStorage(Language.storageKey) private var language = Language.english.rawValue

    var body: some View {
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
            Divider().padding(.vertical, 6)
            AgentSettings()
            Divider().padding(.vertical, 6)
            StayAwakeSettings()
            Divider().padding(.vertical, 6)
            RemoteSettings()
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Settings → keep the Mac awake, lid closed included.
private struct StayAwakeSettings: View {
    @ObservedObject private var awake = StayAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Keep the Mac awake"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Text(L("While Muxy runs, even with the lid closed. Asks for your password once."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { awake.enabled }, set: { awake.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if let problem = awake.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.red)
            } else if awake.enabled, awake.lowBattery {
                Text(L("Paused: battery below %d %%, the Mac may sleep.", StayAwake.batteryFloor))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
            } else if awake.holding {
                Text(L("On: the Mac won't sleep, lid closed included. Mind the heat in a bag."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.green)
            }
        }
    }
}

/// Settings → how "New Session" starts agents.
private struct AgentSettings: View {
    @AppStorage("skipPermissions") private var skipPermissions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            skip
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
