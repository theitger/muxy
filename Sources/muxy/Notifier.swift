import AppKit
import UserNotifications

/// macOS banners. Only available when running from the app bundle — the
/// bare `swift run` executable has no bundle identifier and
/// UserNotifications would crash.
@MainActor
enum Notifier {
    static var available: Bool {
        Paths.isApp
    }

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = delegate
        register([])
    }

    /// Every banner of a session can be answered in place; one with
    /// choices on screen offers them as buttons too.
    static let replyAction = "reply"
    static let choicePrefix = "choice-"
    private static var categories: Set<UNNotificationCategory> = []

    private static func category(for choices: [Choice]) -> String {
        let id = choices.isEmpty ? "session" : "choices-" + choices.map(\.label).joined(separator: "|")
        guard !categories.contains(where: { $0.identifier == id }) else { return id }
        register(choices, id: id)
        return id
    }

    private static func register(_ choices: [Choice], id: String = "session") {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction, title: L("Reply"), options: [],
            textInputButtonTitle: L("Send"), textInputPlaceholder: L("Your answer")
        )
        // Banners show a handful of buttons at most.
        let buttons = choices.prefix(3).map {
            UNNotificationAction(identifier: choicePrefix + String($0.number), title: $0.label, options: [])
        }
        categories.insert(UNNotificationCategory(identifier: id, actions: buttons + [reply], intentIdentifiers: []))
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    /// macOS asks only the first time; later calls change nothing.
    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        content.categoryIdentifier = category(for: Inbox.choices(of: session))
        // One banner per session — a newer event replaces the older one.
        let request = UNNotificationRequest(
            identifier: session.id.uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// A banner with its own words (`muxy notify`); a click opens `session`.
    static func post(title: String, body: String, session: TerminalSession?) {
        guard available, !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let session {
            content.userInfo = ["session": session.id.uuidString]
            content.categoryIdentifier = category(for: [])
        }
        let request = UNNotificationRequest(
            identifier: session?.id.uuidString ?? UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
