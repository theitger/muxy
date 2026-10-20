import Foundation

enum ImplementationWorkflow {
    static let revision = "5beb35b040e3de97e54fa9e386d7e42d15c295c2"
    static let skills = ["implement", "tdd", "code-review", "codebase-design"]

    static func globallyAvailable(home: URL = URL(fileURLWithPath: Paths.home)) -> Bool {
        [".claude/skills", ".agents/skills"].allSatisfy { directory in
            skills.allSatisfy { name in
                FileManager.default.isReadableFile(atPath: home.appendingPathComponent(directory + "/" + name + "/SKILL.md").path)
            }
        }
    }

    static var resources: Bundle {
        // SwiftPM's generated accessor looks beside the executable. App
        // bundles keep resources in Contents/Resources instead.
        if let url = Bundle.main.url(forResource: "muxy_muxy", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }

    static func invocation(for agent: AgentKind?, in root: String) -> String? {
        let paths: [String]
        switch agent {
        case .claude:
            paths = [".claude/skills/implement/SKILL.md", ".claude/commands/implement.md"]
        case .codex:
            paths = [".agents/skills/implement/SKILL.md", ".codex/skills/implement/SKILL.md"]
        case nil: return nil
        }
        guard paths.contains(where: { FileManager.default.isReadableFile(atPath: (root as NSString).appendingPathComponent($0)) }) else { return nil }
        return agent == .claude ? "/implement " : "$implement "
    }

    static var bundledSkill: String? {
        guard let url = resources.url(forResource: "SKILL", withExtension: "md", subdirectory: "Skills/implement"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let end = text.range(of: "\n---\n") else { return nil }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Explicit user installation, shared by all repositories. Existing user
    /// skills win; the vendored originals live in muxy's own versioned folder.
    static func installGlobally(home: URL = URL(fileURLWithPath: Paths.home)) throws {
        let files = FileManager.default
        guard let source = resources.url(forResource: "Skills", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let parent = home.appendingPathComponent(".local/share/muxy/skills")
        let destination = parent.appendingPathComponent(revision)
        if !files.fileExists(atPath: destination.path) {
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(UUID().uuidString)
            do {
                try files.copyItem(at: source, to: staging)
                // Codex has no Claude Skill tool. Its entry points load the
                // unchanged upstream text and explain how to read dependencies.
                for name in skills {
                    let original = try String(contentsOf: source.appendingPathComponent(name + "/SKILL.md"), encoding: .utf8)
                    guard let end = original.range(of: "\n---\n") else { throw CocoaError(.fileReadCorruptFile) }
                    let header = String(original[..<end.upperBound])
                    let directory = staging.appendingPathComponent("codex/" + name)
                    try files.createDirectory(at: directory, withIntermediateDirectories: true)
                    let path = destination.appendingPathComponent(name + "/SKILL.md").path
                    let adapter = "\nRead and apply the original Matt Pocock skill at " + String(reflecting: path)
                        + ". When it refers to the Skill tool or slash commands, read the named skill's SKILL.md under "
                        + String(reflecting: destination.path)
                        + " instead. Resolve relative references from the original skill directory. Follow the user's instructions and authorization.\n"
                    try (header + adapter).write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                    if name == "implement" {
                        try files.createDirectory(at: directory.appendingPathComponent("agents"), withIntermediateDirectories: true)
                        try "policy:\n  allow_implicit_invocation: false\n".write(to: directory.appendingPathComponent("agents/openai.yaml"), atomically: true, encoding: .utf8)
                    }
                }
                try files.moveItem(at: staging, to: destination)
            } catch {
                try? files.removeItem(at: staging)
                throw error
            }
        }
        for (directory, prefix) in [(".claude/skills", ""), (".agents/skills", "codex/")] {
            let root = home.appendingPathComponent(directory)
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            for name in skills {
                let link = root.appendingPathComponent(name)
                if files.fileExists(atPath: link.path) || (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil { continue }
                let target = destination.appendingPathComponent(prefix + name)
                guard files.fileExists(atPath: target.appendingPathComponent("SKILL.md").path) else { throw CocoaError(.fileNoSuchFile) }
                try files.createSymbolicLink(at: link, withDestinationURL: target)
            }
        }
    }

    static func prompt(for issue: Issue, note: String = "", localRepo: String? = nil,
                       template: String? = nil, agent: AgentKind?, root: String,
                       plan: Bool = false, unattended: Bool = false) -> String {
        let invocation = invocation(for: agent, in: root)
        let source = template ?? Issues.template
        let hasPlaceholder = source.contains("{implement}")
        let resolved = source.replacingOccurrences(of: "{implement}", with: invocation ?? "")
        var text = Issues.prompt(for: issue, note: note, localRepo: localRepo, template: resolved,
                                 agent: agent, implement: false, plan: plan, unattended: unattended)
        guard agent != nil else { return text }
        if let invocation, !hasPlaceholder { text = invocation + text }
        return applying(to: text, agent: agent, includeImplement: invocation == nil)
    }

    static func unresolvedIssueTask(_ reference: String, note: String) -> String {
        let task = "Work on issue \(reference)"
        return note.isEmpty ? task : task + "\n\n" + note
    }

    static func unresolvedIssuePrompt(_ reference: String, note: String, agent: AgentKind?) -> String {
        applying(to: unresolvedIssueTask(reference, note: note), agent: agent)
    }

    static func applying(to task: String, agent: AgentKind?, includeImplement: Bool = true) -> String {
        guard agent != nil, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return task }
        guard let implement = bundledSkill,
              let root = resources.url(forResource: "Skills", withExtension: nil) else {
            return task + "\n\nMuxy's bundled implement skill is unavailable. Report this to the user before proceeding."
        }
        var lines = [task, "Muxy supplies Matt Pocock's implement workflow for this task."]
        if includeImplement { lines.append(implement) }
        lines.append("Related skills are bundled at: " + root.path)
        lines.append("If a skill refers to the Skill tool or a slash command that this engine does not provide, read the named skill's SKILL.md in that directory and apply its instructions instead. Relative references stay relative to that skill directory.")
        lines.append("The task text above is the spec. Record the starting HEAD as the code-review fixed point before changing files. For linked GitHub issues, use the provided repository, issue reference and URL as the issue-tracker context. For a standalone task, use its prompt as the spec; no issue-tracker setup is required.")
        lines.append("Follow the user's requested mode: a question or plan request does not authorize implementation. Repository instructions and the user's permissions still apply. Pushing, opening a PR, Quorum and merging remain separate muxy actions unless the user explicitly asked for them.")
        return lines.joined(separator: "\n\n")
    }
}
