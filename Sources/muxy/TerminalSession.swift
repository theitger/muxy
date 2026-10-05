import AppKit
import GhosttyTerminal

/// One terminal tab: a libghostty surface running the user's login shell
/// (Ghostty's own exec backend — real PTY, real Ghostty rendering).
///
/// The user's actual Ghostty config (`~/.config/ghostty/config`) is loaded
/// into the shared controller, so theme, font and feel match their Ghostty.
///
/// Anti-lag rules:
/// - One view per session, created once, only ever *reparented*.
/// - Invisible sessions get `setSurfaceVisible(false)`: the PTY and VT
///   state keep running, rendering stops entirely.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    /// One ghostty app/config instance shared by all surfaces.
    static let controller: TerminalController = {
        Config.prepareGhosttyResources()
        let path = Paths.home + "/.config/ghostty/config"
        let existing = FileManager.default.fileExists(atPath: path) ? path : nil
        // The user's config 1:1 — Ghostty paints its own background too.
        // (Turning that off to let the window paint it renders the default
        // text washed out, so it is not an option.)
        // Empty theme: the wrapper renders its theme AFTER the config file,
        // so any non-empty value would override the user's own colors.
        return TerminalController(
            configFilePath: existing,
            theme: TerminalTheme(light: .init(), dark: .init())
        )
    }()

    let id = UUID()
    let terminalView: TerminalView
    /// The container currently showing this terminal (see TerminalHostView).
    weak var host: NSView?

    /// Live working directory (OSC 7 from the shell).
    @Published private(set) var cwd: String
    @Published private(set) var title: String
    @Published private(set) var context: RepoContext
    @Published private(set) var status: SessionStatus = .running
    @Published var agent: AgentState = .none
    /// Something happened here while you were looking elsewhere — the
    /// single orange signal.
    @Published var needsAttention = false {
        didSet {
            if needsAttention != oldValue { onAttentionChange?() }
        }
    }

    var onAttentionChange: (() -> Void)?
    var onContextChange: (() -> Void)?

    private var contextToken = 0

    init(directory: String) {
        cwd = directory
        title = Paths.folderName(directory)
        context = .plain(directory)
        terminalView = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()

        terminalView.delegate = self
        terminalView.controller = Self.controller
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: directory,
            // Every process in this terminal inherits the session id — the
            // Claude Code hook uses it to route its events back.
            envVars: ["MUXY": "1", "MUXY_SESSION": id.uuidString]
        )
        refreshContext()
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

    /// The session came to the front.
    func markSeen() {
        needsAttention = false
        // A permission prompt you are looking at gets answered — the hook
        // only speaks again at the end of the turn.
        if agent == .blocked { agent = .working }
    }

    /// A foreground command is running in this tab's shell.
    var isBusy: Bool {
        agent == .working || (agent == .none && needsCloseConfirmation)
    }

    /// Tab label: what runs here, not the shell's noisy title.
    var tabTitle: String {
        if agent != .none { return "Claude" }
        let clean = Self.clean(title)
        // An idle shell titles itself with its path — the folder says it shorter.
        if clean.isEmpty || clean.hasPrefix("~") || clean.hasPrefix("/") {
            return context.shortFolder
        }
        return clean
    }

    /// The agent's own title (Claude names the conversation), nil when
    /// nothing meaningful is set.
    var agentTitle: String? {
        guard agent != .none else { return nil }
        let clean = Self.clean(title)
        if clean.isEmpty || clean == "Claude Code" || clean.hasPrefix("claude") || clean.hasPrefix("~")
            || clean.hasPrefix("/") { return nil }
        return clean
    }

    /// Drops leading spinner/status glyphs ("✳ Fix bug" → "Fix bug").
    private static func clean(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber && $0 != "~" && $0 != "/" })
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Context (repo, branch, PR)

    func refreshContext(includePR: Bool = true) {
        contextToken += 1
        let token = contextToken
        let directory = cwd
        Task.detached(priority: .utility) {
            let resolved = Git.context(for: directory)
            await MainActor.run {
                guard token == self.contextToken else { return }
                var context = resolved
                // Keep the known PR while it's the same branch.
                if context.branch == self.context.branch {
                    context.pr = self.context.pr
                    context.checks = self.context.checks
                    context.isDraft = self.context.isDraft
                    context.mergeability = self.context.mergeability
                }
                self.context = context
                self.onContextChange?()
            }
            guard includePR, Git.mayHavePR(resolved.branch) else { return }
            let pr = Git.pullRequest(in: directory)
            await MainActor.run {
                guard token == self.contextToken else { return }
                let before = self.context.checks
                self.context.pr = pr?.number
                self.context.checks = pr?.checks ?? .none
                self.context.isDraft = pr?.isDraft ?? false
                self.context.mergeability = pr?.mergeability ?? .unknown
                self.onContextChange?()
                if before == .pending, let number = pr?.number {
                    switch self.context.checks {
                    case .passed: self.markAttentionIfBackground(reason: L("· #%d passed", number))
                    // Red while something is fixing it is expected — stay quiet.
                    case .failed where Store.shared.workspace(of: self)?.isBusy != true:
                        self.markAttentionIfBackground(reason: L("· #%d failed", number))
                    default: break
                    }
                }
            }
        }
    }
}

extension TerminalSession: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        let clean = Paths.abbreviate(title)
        // Shell integration titles a running command with its command line
        // — the cheapest way to notice an agent started by hand.
        if agent == .none, clean.lowercased().hasPrefix("claude") { agent = .idle }
        self.title = clean
    }
}

extension TerminalSession: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        guard path != cwd else { return }
        cwd = path
        refreshContext()
    }
}

extension TerminalSession: TerminalSurfaceCommandFinishedDelegate {
    func terminalDidFinishCommand(exitCode _: Int?, durationNanos _: UInt64) {
        // Commands inside claude never reach this shell — a finished
        // command here means claude itself exited.
        agent = .none
    }
}

extension TerminalSession: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive _: Bool) {
        status = .exited(nil)
    }
}

extension TerminalSession: TerminalSurfaceBellDelegate {
    func terminalDidRingBell() {
        markAttentionIfBackground(reason: nil)
    }
}

extension TerminalSession: TerminalSurfaceDesktopNotificationDelegate {
    func terminalDidRequestDesktopNotification(title _: String, body _: String) {
        markAttentionIfBackground(reason: nil)
    }
}

extension TerminalSession {
    /// Visible sessions are being watched — only background ones get the
    /// orange signal; the banner only when muxy isn't frontmost.
    func markAttentionIfBackground(reason: String?) {
        if terminalView.window == nil {
            needsAttention = true
        }
        Notifier.post(session: self, reason: reason)
    }
}

enum SessionStatus {
    case running
    case exited(Int32?)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
