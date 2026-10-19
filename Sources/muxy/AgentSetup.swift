import Foundation
import SwiftUI

/// Which agents are installed, and whether muxy's hooks are in their
/// settings. The hooks are how muxy knows an agent is working, done or
/// needs you; HookInstaller writes them. Settings → Agents and the first
/// launch both show this.
@MainActor
final class AgentSetup: ObservableObject {
    static let shared = AgentSetup()

    enum HookState: Equatable {
        case agentNotFound
        case notInstalled
        case installed
        case outdated
        case problem(String)
    }

    struct Agent: Equatable {
        var kind: AgentKind
        /// Where your login shell finds it; nil: not installed.
        var path: String?
        /// The file muxy writes its hooks into.
        var settings: URL
        var hooks: HookState
        /// Codex only: hooks switched off in its config.toml.
        var hooksDisabled = false
    }

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var checked = false
    @Published private(set) var busy = false

    func agent(_ kind: AgentKind) -> Agent? {
        agents.first { $0.kind == kind }
    }

    /// Looks again: agents through the login shell, then every file.
    func refresh() {
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.probe() }.value
            agents = found
            checked = true
        }
    }

    func install(_ kinds: [AgentKind]) {
        busy = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [Agent] in
                for agent in Self.probe() where kinds.contains(agent.kind) && agent.path != nil {
                    _ = try? Self.install(agent)
                }
                return Self.probe()
            }.value
            agents = found
            checked = true
            busy = false
        }
    }

    /// At launch of the app bundle: hooks you installed earlier follow
    /// muxy's updates (a new script, changed events) without a click.
    /// Hooks you never installed stay that way. Not for the dev build, so
    /// it can't rewrite the files a running Muxy.app relies on.
    func maintain() {
        guard Paths.isApp else { return }
        Task {
            let found = await Task.detached(priority: .utility) { () -> [Agent] in
                let agents = Self.probe()
                for agent in agents where agent.hooks == .outdated {
                    _ = try? Self.install(agent)
                }
                return Self.probe()
            }.value
            agents = found
            checked = true
        }
    }

    // MARK: Off the main thread

    nonisolated static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    nonisolated static var scriptURL: URL { HookInstaller.scriptURL(home: home) }

    /// agent-hook.sh as this muxy ships it: inside the app bundle, or the
    /// checkout's Scripts folder for a dev build.
    nonisolated static var bundledScript: Data? {
        let bundled = Paths.isApp
            ? Bundle.main.resourceURL?.appendingPathComponent("agent-hook.sh")
            : URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Scripts/agent-hook.sh")
        return bundled.flatMap { try? Data(contentsOf: $0) }
    }

    nonisolated private static func install(_ agent: Agent) throws {
        guard let script = bundledScript else {
            throw HookInstaller.Failure(message: "agent-hook.sh is missing from this build.")
        }
        try HookInstaller.installScript(script, at: scriptURL)
        try HookInstaller.install(target(agent.kind, settings: agent.settings), script: scriptURL)
    }

    nonisolated private static func target(_ kind: AgentKind, settings: URL) -> HookInstaller.Target {
        HookInstaller.Target(
            agent: kind.rawValue, file: settings,
            hooks: kind == .claude ? HookInstaller.claudeHooks : HookInstaller.codexHooks
        )
    }

    /// One login shell answers where both agents are and where they keep
    /// their settings: the same environment the launcher starts them in.
    nonisolated static func probe() -> [Agent] {
        let marker = "__muxy__"
        let line = "command -v claude; echo \(marker); command -v codex; echo \(marker); "
            + "echo $CLAUDE_CONFIG_DIR; echo \(marker); echo $CODEX_HOME"
        let output = Shell.execute(Paths.userShell, ["-l", "-c", line], in: Paths.home, timeout: 15).output
        // Each answer is the last line before its marker: anything a
        // profile prints ahead of it is noise.
        let parts = output.components(separatedBy: marker).map {
            $0.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        func part(_ index: Int) -> String? {
            let value = index < parts.count ? parts[index] : ""
            return value.hasPrefix("/") ? value : nil
        }
        func found(_ name: String, _ index: Int) -> String? {
            part(index) ?? Shell.find(name)
        }
        let claudeDir = part(2).map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        let codexDir = part(3).map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")

        var claude = Agent(kind: .claude, path: found("claude", 0),
                           settings: claudeDir.appendingPathComponent("settings.json"), hooks: .notInstalled)
        var codex = Agent(kind: .codex, path: found("codex", 1),
                          settings: codexDir.appendingPathComponent("hooks.json"), hooks: .notInstalled)
        claude.hooks = state(of: claude)
        codex.hooks = state(of: codex)
        if let path = codex.path {
            codex.hooksDisabled = codexHooksDisabled(path)
        }
        return [claude, codex]
    }

    nonisolated private static func state(of agent: Agent) -> HookState {
        guard agent.path != nil else { return .agentNotFound }
        switch HookInstaller.status(of: target(agent.kind, settings: agent.settings), script: scriptURL) {
        case .notInstalled: return .notInstalled
        case .outdated: return .outdated
        case .unreadable: return .problem(L("%@ isn't valid JSON, muxy leaves it alone.", agent.settings.lastPathComponent))
        case .installed:
            // The entries are right; the script they run must be current too.
            let current = bundledScript
            return current == nil || (try? Data(contentsOf: scriptURL)) == current ? .installed : .outdated
        }
    }

    /// Codex runs hooks unless config.toml sets `[features] hooks = false`
    /// (older versions called it `codex_hooks`). Asked from Codex itself,
    /// which knows its own defaults and CODEX_HOME.
    nonisolated private static func codexHooksDisabled(_ codex: String) -> Bool {
        let quoted = "'" + codex.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let output = Shell.execute(Paths.userShell, ["-l", "-c", "\(quoted) features list"], in: Paths.home, timeout: 15).output
        return output.split(separator: "\n").contains { line in
            let words = line.split(separator: " ")
            guard let name = words.first, let value = words.last else { return false }
            return (name == "hooks" || name == "codex_hooks") && value == "false"
        }
    }
}

/// Settings → Agents: per agent whether muxy's hooks are in place, with
/// the button that puts them there.
struct HookSettings: View {
    @ObservedObject private var setup = AgentSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Agent hooks"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textBody)
                Text(L("How muxy knows an agent is working, done or needs you."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if setup.checked {
                ForEach(setup.agents, id: \.kind) { HookRow(agent: $0) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { setup.refresh() }
    }
}

/// One agent: glyph, name, what's installed, and Install or Update.
struct HookRow: View {
    let agent: AgentSetup.Agent
    /// Off where one button installs for every agent at once.
    var showsAction = true
    @ObservedObject private var setup = AgentSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AgentGlyph(kind: agent.kind, size: 13)
                Text(agent.kind.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(state.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(state.color)
                    .lineLimit(1)
                Spacer()
                if showsAction, let action {
                    Button(action) { setup.install([agent.kind]) }
                        .controlSize(.small)
                        .disabled(setup.busy)
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var state: (text: String, color: Color) {
        switch agent.hooks {
        case .agentNotFound: (L("Not installed on this Mac"), Theme.textDim)
        case .notInstalled: (L("Hooks not installed"), Theme.orange.strong)
        case .outdated: (L("Hooks outdated"), Theme.orange.strong)
        case .installed: (L("Hooks installed"), Theme.green)
        case let .problem(message): (message, Theme.red)
        }
    }

    private var action: String? {
        switch agent.hooks {
        case .notInstalled: L("Install")
        case .outdated: L("Update")
        default: nil
        }
    }

    private var note: String? {
        guard agent.kind == .codex, agent.path != nil else { return nil }
        if agent.hooksDisabled {
            return L("Hooks are switched off in Codex: remove hooks = false under [features] in its config.toml.")
        }
        if agent.hooks == .installed || agent.hooks == .outdated {
            return L("Codex runs new hooks only once you trust them: type /hooks in Codex and trust muxy's.")
        }
        return nil
    }
}
