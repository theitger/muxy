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
            window.openReview(scope: value == "branch" ? .branch : .lastTurn)
        case "close-review":
            window.closeReview()
        case "appearance":
            AppAppearance.apply(value.flatMap(AppAppearance.init) ?? .system)
        case "panel":
            Results.shared.togglePanel(in: window)
        case "select":
            if let index = value.flatMap(Int.init) { window.selectWorkspace(index: index) }
        case "open":
            if let value { window.newWorkspace(directory: value) }
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
