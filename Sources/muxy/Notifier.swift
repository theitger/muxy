import AppKit
import UserNotifications

/// macOS banners. Only available when running from the app bundle — the
/// bare `swift run` executable has no bundle identifier and
/// UserNotifications would crash.
@MainActor
enum Notifier {
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestPermission(delegate: UNUserNotificationCenterDelegate) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Banner only when muxy is not the active app — inside the app the
    /// orange signal is enough. Clicking it opens the session.
    static func post(session: TerminalSession, reason: String?) {
        guard available, !NSApplication.shared.isActive else { return }
        let workspace = Store.shared.workspace(of: session)
        let name = workspace?.title ?? session.tabTitle
        let content = UNMutableNotificationContent()
        content.title = reason.map { "\(name) \($0)" } ?? name
        if let workspace {
            content.body = [workspace.context.repo, workspace.subtitle].compactMap { $0 }.joined(separator: " · ")
        }
        content.sound = .default
        content.userInfo = ["session": session.id.uuidString]
        // One banner per session — a newer event replaces the older one.
        let request = UNNotificationRequest(
            identifier: session.id.uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
