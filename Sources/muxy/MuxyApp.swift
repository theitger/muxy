import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        AppAppearance.apply()
        Notifier.setUp(delegate: self)
        // On the first launch the setup asks, with a reason, instead.
        if !Onboarding.isDue { Notifier.requestPermission() }
        AgentSetup.shared.maintain()
        Onboarding.showIfDue()
        Updater.shared.start()
        QuickTerminal.shared.start()
    }

    /// Like Ghostty with `quit-after-last-window-closed = false`: closing the
    /// last window leaves muxy running; the Dock icon opens a new one.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // "Install and Relaunch" already said yes, and sessions come back.
        if Updater.shared.installing, Store.shared.restoreOnLaunch {
            Store.shared.saveSessions()
            return .terminateNow
        }
        return Store.shared.shouldQuit() ? .terminateNow : .terminateCancel
    }

    /// Banner click → that session.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["session"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            defer { completion() }
            guard let id else { return }
            // Answered from the banner: the session gets it where it is.
            if let session = Store.shared.session(id: id) {
                if action == Notifier.replyAction, let text {
                    Inbox.reply(text, to: session)
                    return
                }
                // Only while that question is still on screen: a digit
                // must never answer a newer one.
                if action.hasPrefix(Notifier.choicePrefix), let number = Int(action.dropFirst(Notifier.choicePrefix.count)),
                   let choice = Inbox.choices(of: session).first(where: { $0.number == number }) {
                    Inbox.choose(choice, in: session)
                    return
                }
            }
            Store.shared.focus(sessionID: id)
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
        // Tabs run your login shell, not whatever SHELL muxy inherited (a
        // zsh from the terminal or agent that started it): libghostty picks
        // SHELL first.
        setenv("SHELL", Paths.userShell, 1)

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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
            CommandGroup(replacing: .newItem) {
                Button(L("New Session")) { store.newWorkspaceInFront() }
                    .keyboardShortcut("n", modifiers: .command)
                Button(L("New Shell")) { store.newShellInFront() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button(L("New Window")) { store.newWindow() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("New Tab")) { store.newTabInFront() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button(L("Close Tab")) { store.activeWindow?.closeCurrent() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button(L("Find in Terminal…")) {
                    store.activeWindow?.selectedWorkspace?.selectedSession?.startSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu(L("Sessions")) {
                Button(L("Search…")) { store.activeWindow?.showSwitcher.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button(L("Next one waiting")) { store.jumpToAttention() }
                    .keyboardShortcut("j", modifiers: .command)
                Button(L("Inbox")) { store.toggleInbox() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
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
                Button(store.detailedWings ? L("Simple Sessions") : L("Detailed Sessions")) {
                    store.toggleDetailedWings()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button(L("Set Up muxy Again…")) { Onboarding.show() }
            }
        }

        Settings {
            SettingsView()
        }
    }
}
