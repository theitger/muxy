#if DEBUG
import AppKit

/// Development builds only: `{"command":"debug","action":…}` requests open
/// the hub, the review or the result panel and save a window as a PNG, so
/// a change can be looked at without screen-recording rights.
@MainActor
enum DebugDriver {
    static func handle(action: String, value: String?, store: Store, reply: (Bool, String) -> Void) {
        guard let window = store.activeWindow ?? store.windows.first else { return reply(false, "no window") }
        switch action {
        case "hub":
            UserDefaults.standard.set(value ?? "board", forKey: "hubPage")
            window.showHub = true
        case "close-hub":
            window.showHub = false
        case "new-session":
            window.showNewSession.toggle()
        case "review":
            if value == "accept" { window.openAcceptance() }
            else { window.openReview(scope: value == "branch" ? .branch : .lastTurn) }
        case "close-review":
            window.closeReview()
        case "quorum":
            if let value {
                guard let status = QuorumWatch.shared.byKey[value] else { return reply(false, "run not found") }
                window.openQuorumRun(status)
            } else {
                window.reviewRun = nil
            }
        case "task":
            if let value, let reference = IssueRef.parse(value), let repo = reference.repo {
                let issue = HubModel.shared.issues.first { $0.repo.lowercased() == repo.lowercased() && $0.number == reference.number }
                    ?? Queue.shared.items.first { $0.issue.repo.lowercased() == repo.lowercased() && $0.issue.number == reference.number }?.issue
                    ?? Issue(repo: repo, number: reference.number, title: "#\(reference.number)", url: "https://github.com/\(repo)/issues/\(reference.number)", state: "OPEN")
                window.openTask(TaskTarget(issue: issue))
            } else if let workspace = window.selectedWorkspace { window.openTask(TaskTarget(workspace: workspace)) }
            else { return reply(false, "no task") }
        case "task-section":
            window.taskSection = value ?? "overview"
        case "appearance":
            AppAppearance.apply(value.flatMap(AppAppearance.init) ?? .system)
        case "terminal-colors":
            TerminalColors.select(value.flatMap(TerminalColors.init) ?? .ghostty)
        case "panel":
            Results.shared.togglePanel(in: window)
        case "select":
            if let index = value.flatMap(Int.init) { window.selectWorkspace(index: index) }
        case "open":
            if let value { window.newWorkspace(directory: value) }
        case "font":
            UserDefaults.standard.set(value ?? "", forKey: TerminalColors.fontKey)
            TerminalColors.apply()
        case "titles":
            let text = store.workspaces.map { ws in
                ws.sessions.map { "[\($0.title)] agentTitle=\($0.agentTitle ?? "nil") cwd=\($0.cwd) root=\(ws.context.root ?? "nil") checkout=\(ws.context.checkout ?? "nil")" }.joined(separator: " | ")
            }.joined(separator: "\n")
            return reply(true, text)
        case "ports":
            guard let workspace = window.selectedWorkspace else { return reply(false, "no workspace") }
            return reply(true, Previews.shared.ports(of: workspace).map { "\($0.port):\($0.isWeb)" }.joined(separator: ", "))
        case "preview-device":
            NotificationCenter.default.post(name: Notification.Name("muxy.debug.previewDevice"), object: value)
        case "review-feedback":
            NotificationCenter.default.post(name: Notification.Name("muxy.debug.reviewFeedback"), object: value)
        case "review-surface":
            NotificationCenter.default.post(name: Notification.Name("muxy.debug.reviewSurface"), object: value)
        case "sidebar":
            store.toggleSidebar()
        case "chrome":
            guard let nsWindow = window.nsWindow, let close = nsWindow.standardWindowButton(.closeButton) else { return reply(false, "no window") }
            let frame = close.convert(close.bounds, to: nil)
            let fromTop = nsWindow.frame.height - frame.midY
            let titlebar = nsWindow.frame.height - nsWindow.contentLayoutRect.height
            return reply(true, "close button center \(fromTop) from top, titlebar \(titlebar), window \(nsWindow.frame.height)")
        case "settings":
            if let value, SettingsView.Pane(rawValue: value) != nil {
                UserDefaults.standard.set(value, forKey: "settingsPane")
            }
            store.openSettings?()
        case "shot-other":
            // The newest window that isn't a session window (Settings).
            guard let value, let other = NSApplication.shared.windows.last(where: { win in
                win.isVisible && !store.windows.contains { $0.nsWindow === win }
            }), let view = other.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return reply(false, "no window") }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: value))
        case "shot":
            guard let value, let view = window.nsWindow?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return reply(false, "no view") }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]),
                  (try? data.write(to: URL(fileURLWithPath: value))) != nil else { return reply(false, "can't write") }
        default:
            return reply(false, "unknown debug action")
        }
        reply(true, "")
    }
}
#endif
