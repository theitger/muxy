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
    /// Which agent runs here, once one does.
    @Published var kind: AgentKind?
    /// Claude's conversation log, as the hook reports it — the remote
    /// renders it as a chat.
    var transcriptPath: String?
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
    /// The surface runs an agent directly (see `init`); the first prompt
    /// of the shell that follows it means the agent has exited.
    private var runsAgent = false
    private let environment: [String: String]
    private let command: String?

    /// Its folder is still being made (a new worktree): the tab exists, its
    /// surface starts with `begin(in:)`.
    @Published private(set) var preparing: String?

    /// `command` runs instead of a bare shell (an agent, followed by your
    /// shell when it exits); `environment` reaches every process in the tab.
    init(directory: String, command: String? = nil, environment: [String: String] = [:], preparing: String? = nil) {
        cwd = directory
        title = Paths.folderName(directory)
        context = .plain(directory)
        terminalView = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.environment = environment
        self.command = command
        self.preparing = preparing
        runsAgent = command != nil
        super.init()

        terminalView.delegate = self
        if preparing == nil { begin(in: directory) }
    }

    /// Starts the surface: right away, or once its folder exists.
    func begin(in directory: String) {
        preparing = nil
        if directory != cwd {
            cwd = directory
            title = Paths.folderName(directory)
        }
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: directory,
            // Every process in this terminal inherits the session id — the
            // Claude Code hook uses it to route its events back.
            envVars: environment.merging(["MUXY": "1", "MUXY_SESSION": id.uuidString]) { _, ours in ours },
            command: command
        )
        terminalView.controller = Self.controller
        refreshContext()
    }

    /// What the folder is waiting for now (a checkout, a bootstrap).
    func updatePreparing(_ step: String) {
        if preparing != nil { preparing = step }
    }

    /// The folder never came: the tab says why instead of a terminal.
    func failPreparing(_ message: String) {
        preparing = message
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
        if agent != .none { return kind?.name ?? "Agent" }
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
        if clean.isEmpty || clean == "Claude Code" || AgentKind(commandLine: clean) != nil || clean.hasPrefix("~")
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

extension TerminalSession {
    func agentExited() {
        agent = .none
        kind = nil
        transcriptPath = nil
    }
}

extension TerminalSession: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) {
        let clean = Paths.abbreviate(title)
        // Shell integration titles a running command with its command line
        // — the cheapest way to notice an agent started by hand.
        if agent == .none, let detected = AgentKind(commandLine: clean) {
            kind = detected
            agent = .idle
        }
        self.title = clean
    }
}

extension TerminalSession: TerminalSurfacePwdDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String) {
        // Agents report no directory; the shell after one does, on its
        // first prompt: the agent has exited.
        if runsAgent {
            runsAgent = false
            agentExited()
        }
        guard path != cwd else { return }
        cwd = path
        refreshContext()
    }
}

extension TerminalSession: TerminalSurfaceCommandFinishedDelegate {
    func terminalDidFinishCommand(exitCode _: Int?, durationNanos _: UInt64) {
        // Commands inside claude never reach this shell — a finished
        // command here means claude itself exited.
        agentExited()
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
