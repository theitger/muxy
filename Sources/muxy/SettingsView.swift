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
            RemoteSettings()
        }
        .padding(20)
        .frame(width: 440)
    }
}
