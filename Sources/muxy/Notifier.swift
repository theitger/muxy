import AppKit
import UserNotifications

/// macOS banner notifications. Only available when running from the app
/// bundle — the bare `swift run` executable has no bundle identifier and
/// UserNotifications would crash.
enum Notifier {
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    /// Banner only when muxy is not the active app — inside the app the
    /// orange dot is the signal.
    static func postIfInactive(title: String, body: String) {
        guard available, !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
