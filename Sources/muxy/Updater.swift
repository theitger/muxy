import AppKit
import Combine
import Sparkle
import SwiftUI

/// Self-updates through Sparkle: checks the appcast in the background (once
/// a day) and on demand from the app menu, then offers to install and
/// relaunch. Only in a release bundle with a feed and a signing key: the bare
/// `swift run` executable has no bundle and nothing to update.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// False while a check or an install is under way.
    @Published private(set) var canCheck = false
    /// Sparkle's own setting, persisted by Sparkle in muxy's defaults.
    @Published private(set) var automaticChecks = false
    /// Sparkle is about to quit muxy to install an update.
    private(set) var installing = false

    private var controller: SPUStandardUpdaterController?
    private var observers: Set<AnyCancellable> = []

    var available: Bool { controller != nil }

    /// Release bundles carry both; without the public key Sparkle refuses to
    /// start and says so in an alert.
    static var configured: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    func start() {
        guard controller == nil, Self.configured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &observers)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticChecks = $0 }
            .store(in: &observers)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle calls this on the main thread right before it quits muxy.
    nonisolated func updaterWillRelaunchApplication(_: SPUUpdater) {
        MainActor.assumeIsolated { installing = true }
    }
}

/// App menu → "Check for Updates…", only where updates exist.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if updater.available {
            Button(L("Check for Updates…")) { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
    }
}

/// Settings → automatic update checks. Hidden in builds that can't update.
struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        if updater.available {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Check for updates automatically"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Text(L("Once a day. Muxy %@ asks before it installs anything.", version))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { updater.automaticChecks },
                    set: { updater.setAutomaticChecks($0) }
                ))
                .labelsHidden()
                .toggleStyle(.offOn)
                .accessibilityLabel(L("Check for updates automatically"))
            }
        }
    }
}
