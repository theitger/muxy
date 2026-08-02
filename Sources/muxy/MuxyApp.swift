import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        Notifier.requestPermission()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}

@main
struct MuxyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()

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
        // Single-window app: `Window` (not WindowGroup) prevents macOS
        // from restoring/stacking multiple windows at launch.
        Window("muxy", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neuer Tab") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Neues Terminal") { store.newTerminalWorkspace() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Neuer Worktree…") { store.showNewWorktreeSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Tab schließen") { store.closeCurrent() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Worktrees neu laden") { store.refreshWorktrees() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            // ⌘1..9 (Tab-Wechsel) läuft über den Key-Monitor im Store —
            // die Ghostty-Surface schluckt Menü-Shortcuts.
            CommandMenu("Öffnen") {
                Button("Terminal (Home)") { store.newTerminalWorkspace() }
                Divider()
                ForEach(store.projects) { project in
                    let trees = store.worktrees[project.path] ?? []
                    if trees.count <= 1 {
                        Button(project.name) {
                            store.openWorktree(
                                trees.first ?? Worktree(
                                    path: project.path, branch: "", projectPath: project.path
                                )
                            )
                        }
                    } else {
                        Menu(project.name) {
                            ForEach(trees) { worktree in
                                Button(worktree.isMain ? "main" : worktree.name) {
                                    store.openWorktree(worktree)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Projektliste bearbeiten…") {
                    NSWorkspace.shared.open(Store.projectsFile)
                }
            }
        }
    }
}
