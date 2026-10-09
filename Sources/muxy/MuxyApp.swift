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
    /// Menus are rebuilt in the new language right away.
    @AppStorage(Language.storageKey) private var language = Language.english.rawValue

    init() {
        // Standard menus (Edit, Window, …) follow the app's language, not the
        // system's — must be set before AppKit first resolves localizations.
        UserDefaults.standard.set([Language.current.rawValue], forKey: "AppleLanguages")

        // Started from inside an agent's shell (`swift run`, a script),
        // muxy would hand that agent's session markers to every tab, and
        // agents there would think they run nested. muxy's tabs are new
        // top-level terminals.
        for name in ProcessInfo.processInfo.environment.keys
            where name == "CLAUDECODE" || name == "CLAUDE_PID" || name.hasPrefix("CLAUDE_CODE_") {
            unsetenv(name)
        }

        // Never restore windows across launches.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])

        // Stale `swift run` processes of this same binary each keep a window
        // around — replace them. Other installs (another bundle) are left
        // alone: killing them would end their sessions.
        let me = NSRunningApplication.current
        for app in NSWorkspace.shared.runningApplications
            where app.processIdentifier != me.processIdentifier
            && app.executableURL == me.executableURL {
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
                Button(L("New Session")) { store.newWorkspaceInFront() }
                    .keyboardShortcut("n", modifiers: .command)
                Button(L("New Window")) { store.newWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("New Tab")) { store.newTabInFront() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button(L("Close Tab")) { store.activeWindow?.closeCurrent() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu(L("Sessions")) {
                Button(L("Search…")) { store.activeWindow?.showSwitcher.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button(L("Next one waiting")) { store.jumpToAttention() }
                    .keyboardShortcut("j", modifiers: .command)
                Divider()
                Button(L("Previous Session")) { store.activeWindow?.selectWorkspace(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(L("Next Session")) { store.activeWindow?.selectWorkspace(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button(L("Next Tab")) { store.activeWindow?.selectTab(offset: 1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Divider()
                Button(store.sidebarVisible ? L("Hide Sidebar") : L("Show Sidebar")) {
                    store.toggleSidebar()
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
