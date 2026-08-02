import AppKit
import GhosttyTerminal

/// One terminal tab: a libghostty surface running the user's login shell
/// (Ghostty's own exec backend — real PTY, real Ghostty rendering).
///
/// The user's actual Ghostty config (`~/.config/ghostty/config`) is loaded
/// into the shared controller, so theme, font and feel match their Ghostty.
///
/// Anti-lag rules, learned from cmux issue #4101:
/// - One view per session, created once, only ever *reparented*.
/// - Invisible sessions get `setSurfaceVisible(false)`: the PTY and VT
///   state keep running, rendering stops entirely.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    /// One ghostty app/config instance shared by all surfaces.
    static let controller: TerminalController = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config").path
        let existing = FileManager.default.fileExists(atPath: path) ? path : nil
        // Empty theme: the wrapper renders its theme AFTER the config file,
        // so any non-empty value would override the user's own colors.
        return TerminalController(
            configFilePath: existing,
            theme: TerminalTheme(light: .init(), dark: .init())
        )
    }()

    let id = UUID()
    let worktree: Worktree
    let agent: AgentKind
    let terminalView: TerminalView

    @Published var status: SessionStatus = .running
    @Published var title: String
    /// Bell/notification from the terminal (e.g. Claude wants input) while
    /// the session is not in front — shown as the single orange dot.
    @Published var needsAttention = false

    var name: String { worktree.name }

    init(worktree: Worktree, agent: AgentKind) {
        self.worktree = worktree
        self.agent = agent
        self.title = worktree.name
        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        terminalView.delegate = self
        terminalView.controller = Self.controller
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: worktree.path,
            // Every process in this terminal inherits the session id — the
            // Claude Code hook uses it to route "done/needs input" back.
            envVars: ["MUXY": "1", "MUXY_SESSION": id.uuidString]
        )
    }

    /// Ghostty's own logic: confirm only when foreground work is running
    /// (claude, builds, …) — an idle shell closes silently.
    var needsCloseConfirmation: Bool {
        guard status.isRunning else { return false }
        return terminalView.currentSurface?.needsConfirmQuit() ?? false
    }

    /// Dropping the session releases the surface, which tears down the
    /// child process; hiding first stops any in-flight rendering.
    func terminate() {
        terminalView.setSurfaceVisible(false)
        terminalView.removeFromSuperview()
    }
}

extension TerminalSession: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        // "/Users/x" → "~", bare home-folder name ("theitger") → "~".
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var clean = title.replacingOccurrences(of: home, with: "~")
        if clean == (home as NSString).lastPathComponent {
            clean = "~"
        }
        DispatchQueue.main.async { self.title = clean }
    }
}

extension TerminalSession: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive _: Bool) {
        DispatchQueue.main.async { self.status = .exited(nil) }
    }
}

extension TerminalSession: TerminalSurfaceBellDelegate {
    func terminalDidRingBell() {
        markAttentionIfBackground()
    }
}

extension TerminalSession: TerminalSurfaceDesktopNotificationDelegate {
    func terminalDidRequestDesktopNotification(title _: String, body _: String) {
        markAttentionIfBackground()
    }
}

extension TerminalSession {
    /// The visible session is being watched — only background sessions
    /// get the orange dot. (Detached views have no window.)
    /// `agent` names who is waiting ("Claude", "Codex") — from the hook
    /// pipeline; bell events don't know and fall back to the session title.
    func markAttentionIfBackground(agent: String? = nil) {
        DispatchQueue.main.async {
            if self.terminalView.window == nil {
                self.needsAttention = true
            }
            Notifier.postIfInactive(title: "\(agent ?? self.title) wartet auf dich", body: "")
        }
    }
}
