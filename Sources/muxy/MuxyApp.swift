import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        Notifier.requestPermission(delegate: self)
    }

    /// Like Ghostty with `quit-after-last-window-closed = false`: closing the
    /// last window leaves muxy running; the Dock icon opens a new one.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        Store.shared.shouldQuit() ? .terminateNow : .terminateCancel
    }

    /// Banner click → that session.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            if let id { Store.shared.focus(sessionID: id) }
            completion()
        }
    }
}

@main
struct MuxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    init() {
        // Never restore windows across launches.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])

        // Single instance: stale `swift run` processes each keep a window
        // around — kill any older muxy before this one takes over.
        let me = NSRunningApplication.current
        for app in NSWorkspace.shared.runningApplications
            where app.processIdentifier != me.processIdentifier
            && app.executableURL?.lastPathComponent == "muxy" {
            app.forceTerminate()
        }

        // Running as a bare SwiftPM executable: promote to a regular app
        // with a Dock icon and key-window capability.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        // One scene per muxy window; the value names its WindowModel.
        WindowGroup(id: "main", for: WindowModel.ID.self) { $windowID in
            WindowRoot(windowID: $windowID)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        // Shortcuts are handled by the key monitor in Store (the Ghostty
        // surface swallows menu key equivalents); the menus list them.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neue Session") { store.newWorkspaceInFront() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Neues Fenster") { store.newWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Neuer Tab") { store.newTabInFront() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("Tab schließen") { store.activeWindow?.closeCurrent() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Sessions") {
                Button("Suchen…") { store.activeWindow?.showSwitcher.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Nächste, die wartet") { store.jumpToAttention() }
                    .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button("Vorherige Session") { store.activeWindow?.selectWorkspace(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Nächste Session") { store.activeWindow?.selectWorkspace(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Nächster Tab") { store.activeWindow?.selectTab(offset: 1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Divider()
                Button(store.sidebarVisible ? "Seitenleiste ausblenden" : "Seitenleiste einblenden") {
                    store.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }
    }
}
