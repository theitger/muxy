import SwiftUI

/// quorum's settings as muxy shows them: a few keys of its config file
/// (~/.config/quorum/config, `KEY=value`, comments), changed in place so
/// quorum's own comments and every other key stay as they are.
enum QuorumConfig {
    static let path = Paths.home + "/.config/quorum/config"

    static func read(at path: String = path) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let (key, value) = assignment(String(line)) else { continue }
            values[key] = value
        }
        return values
    }

    /// Sets `key`, keeping a comment after the value; appends it when the
    /// file doesn't have it yet.
    static func write(_ key: String, _ value: String, at path: String = path) {
        guard Worktrees.isVariableName(key) else { return }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = text.components(separatedBy: "\n")
        let rendered = value.allSatisfy({ $0.isNumber }) && !value.isEmpty ? value : "\"\(value.replacingOccurrences(of: "\"", with: ""))\""
        var found = false
        for index in lines.indices {
            guard let (name, _) = assignment(lines[index]), name == key else { continue }
            let comment = lines[index].range(of: "\t#").map { String(lines[index][$0.lowerBound...]) }
                ?? lines[index].range(of: " #").map { String(lines[index][$0.lowerBound...]) } ?? ""
            lines[index] = "\(key)=\(rendered)\(comment)"
            found = true
        }
        if !found {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(key)=\(rendered)")
            lines.append("")
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// "KEY=value  # comment" → (KEY, value without quotes).
    static func assignment(_ line: String) -> (String, String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.hasPrefix("#"), let equals = text.firstIndex(of: "=") else { return nil }
        let key = String(text[..<equals])
        guard Worktrees.isVariableName(key) else { return nil }
        var value = String(text[text.index(after: equals)...])
        if value.hasPrefix("\"") {
            value.removeFirst()
            value = String(value.prefix { $0 != "\"" })
        } else {
            value = String(value.prefix { $0 != "#" && $0 != "\t" }).trimmingCharacters(in: .whitespaces)
        }
        return (key, value)
    }

    /// Whether quorum's background agent (launchd) runs, from its own
    /// status line. Blocking.
    static func agentInstalled() -> Bool? {
        guard let quorum = Shell.find("quorum") else { return nil }
        let result = Shell.execute(quorum, ["status"], in: Paths.home, timeout: 15)
        guard result.status == 0 else { return nil }
        let head = result.output.split(separator: "\n").first.map(String.init) ?? ""
        return !head.contains("agent not installed")
    }
}

/// Settings → Review: quorum, built in. Installs it (in a terminal you can
/// watch), runs its background agent or not, and sets what matters.
struct QuorumSettings: View {
    @State private var values: [String: String] = [:]
    @State private var agent: Bool?
    @State private var installed = Quorum.isInstalled
    @State private var busy = false

    private static let engines = ["codex", "claude", "grok"]
    private static let efforts = ["low", "medium", "high", "xhigh"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Review with quorum"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textBody)
                    Text(L("A panel of reviewers that finds what's wrong in a pull request, fixes it and waits for CI. Landing uses it before it merges."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !installed {
                    Button(L("Install")) { install() }
                }
            }
            if installed {
                row(L("Review engine")) { picker("REVIEW_ENGINE", Self.engines, fallback: "codex") }
                row(L("Review effort")) { picker("REVIEW_EFFORT", Self.efforts, fallback: "medium") }
                row(L("Reviewers per round")) {
                    Stepper(values["REVIEWERS"] ?? "6", value: intBinding("REVIEWERS", fallback: 6), in: 1 ... 12)
                        .monospacedDigit()
                }
                row(L("Fix engine")) { picker("FIX_ENGINE", Self.engines, fallback: "codex") }
                row(L("Fix effort")) { picker("FIX_EFFORT", Self.efforts, fallback: "high") }
                toggle(L("Post reviews on GitHub"), key: "POST", fallback: true)
                toggle(L("Bring branches up to date and resolve conflicts"), key: "RESOLVE_CONFLICTS", fallback: false)
                toggle(L("Merge after a clean babysit"), key: "AUTO_MERGE_BABYSIT", fallback: false)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Review requests on its own"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textBody)
                        Text(L("quorum's agent checks every few minutes for pull requests that ask for your review."))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if let agent {
                        Toggle("", isOn: Binding(get: { agent }, set: { setAgent($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                HStack(spacing: 12) {
                    Button(L("Open the whole config")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: QuorumConfig.path))
                    }
                    .buttonStyle(.link)
                    Text("yungweng/quorum")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                }
                .font(.system(size: 11.5))
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        installed = Quorum.isInstalled
        values = QuorumConfig.read()
        guard installed else { return }
        Task.detached(priority: .utility) {
            let state = QuorumConfig.agentInstalled()
            await MainActor.run { agent = state }
        }
    }

    private func set(_ key: String, _ value: String) {
        values[key] = value
        QuorumConfig.write(key, value)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.textBody)
            Spacer()
            content()
        }
    }

    private func picker(_ key: String, _ options: [String], fallback: String) -> some View {
        Picker("", selection: Binding(get: { values[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback }, set: { set(key, $0) })) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 130)
    }

    private func intBinding(_ key: String, fallback: Int) -> Binding<Int> {
        Binding(get: { values[key].flatMap(Int.init) ?? fallback }, set: { set(key, String($0)) })
    }

    private func toggle(_ title: String, key: String, fallback: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.textBody)
            Spacer()
            Toggle("", isOn: Binding(
                get: { values[key].map { $0 == "1" } ?? fallback },
                set: { set(key, $0 ? "1" : "0") }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    /// quorum's own installer, in a muxy session where you see every step.
    private func install() {
        guard let window = Store.shared.activeWindow ?? Store.shared.windows.first else { return }
        let workspace = Store.shared.makeWorkspace(directory: Paths.home, in: window)
        window.select(workspace)
        Store.shared.runInNewTab(
            "brew tap yungweng/tap && (brew trust yungweng/tap 2>/dev/null; true) && brew install yungweng/tap/quorum && quorum doctor",
            in: workspace
        )
        if let first = workspace.sessions.first, workspace.sessions.count > 1 { Store.shared.close(first, in: workspace) }
        window.bringToFront()
    }

    private func setAgent(_ on: Bool) {
        guard let quorum = Shell.find("quorum") else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            _ = Shell.execute(quorum, [on ? "install" : "uninstall"], in: Paths.home, timeout: 60)
            let state = QuorumConfig.agentInstalled()
            await MainActor.run {
                agent = state
                busy = false
            }
        }
    }
}
