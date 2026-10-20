import XCTest
@testable import muxy

final class ImplementationWorkflowTests: XCTestCase {
    private var issue: Issue { Issue(repo: "o/r", number: 7, title: "Fix login", url: "https://github.com/o/r/issues/7", state: "OPEN", body: "Keep recovery working.") }

    func testOriginalSkillAndDependenciesAreBundled() throws {
        let skill = try XCTUnwrap(ImplementationWorkflow.bundledSkill)
        XCTAssertTrue(skill.contains("Run typechecking regularly"))
        XCTAssertTrue(skill.contains("Commit your work to the current branch."))
        let root = try XCTUnwrap(ImplementationWorkflow.resources.url(forResource: "Skills", withExtension: nil))
        for name in ["tdd/SKILL.md", "tdd/tests.md", "tdd/mocking.md", "code-review/SKILL.md", "codebase-design/SKILL.md", "LICENSE", "SOURCE.md"] {
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: root.appendingPathComponent(name).path), name)
        }
    }

    func testEveryRepositoryGetsTheOriginalWorkflowForBothAgents() throws {
        let repo = try TempRepo()
        for agent in AgentKind.allCases {
            let prompt = ImplementationWorkflow.prompt(for: issue, template: Issues.defaultTemplate, agent: agent, root: repo.root)
            XCTAssertTrue(prompt.contains("Keep recovery working."))
            XCTAssertTrue(prompt.contains(try XCTUnwrap(ImplementationWorkflow.bundledSkill)))
            XCTAssertFalse(prompt.hasPrefix("/implement"))
            XCTAssertFalse(prompt.hasPrefix("$implement"))
        }
    }

    func testRepositorySkillsUseTheCorrectAgentAndAreNotRewritten() throws {
        let repo = try TempRepo()
        try repo.write(".claude/skills/implement/SKILL.md", "Claude skill")
        XCTAssertEqual(ImplementationWorkflow.invocation(for: .claude, in: repo.root), "/implement ")
        XCTAssertNil(ImplementationWorkflow.invocation(for: .codex, in: repo.root))
        try repo.write(".agents/skills/implement/SKILL.md", "Codex skill")
        let prompt = ImplementationWorkflow.prompt(for: issue, template: Issues.defaultTemplate, agent: .codex, root: repo.root)
        XCTAssertTrue(prompt.hasPrefix("$implement "))
        XCTAssertFalse(prompt.contains("/implement"))
        XCTAssertEqual(try String(contentsOfFile: repo.root + "/.agents/skills/implement/SKILL.md"), "Codex skill")
    }

    func testCustomTemplateAndShellRetainTaskContent() throws {
        let repo = try TempRepo()
        let template = "{reference}: {title}\n\n{body}"
        let prompt = ImplementationWorkflow.prompt(for: issue, template: template, agent: nil, root: repo.root)
        XCTAssertEqual(prompt, "o/r#7: Fix login\n\nKeep recovery working.")
        XCTAssertEqual(ImplementationWorkflow.applying(to: "", agent: .codex), "")
        XCTAssertEqual(ImplementationWorkflow.applying(to: "ls", agent: nil), "ls")
    }

    func testUnresolvedIssueGetsTheImplementationWorkflow() throws {
        let prompt = ImplementationWorkflow.unresolvedIssuePrompt("#7", note: "Keep recovery working.", agent: .codex)

        XCTAssertTrue(prompt.hasPrefix("Work on issue #7\n\nKeep recovery working."))
        XCTAssertTrue(prompt.contains(try XCTUnwrap(ImplementationWorkflow.bundledSkill)))
    }

    func testGlobalInstallationKeepsUserSkillsAndWorksWithoutRepoFiles() throws {
        let home = try TempRepo()
        try home.write(".claude/skills/code-review/SKILL.md", "User's own review")
        let root = URL(fileURLWithPath: home.root)
        XCTAssertFalse(ImplementationWorkflow.globallyAvailable(home: root))
        try ImplementationWorkflow.installGlobally(home: root)
        try ImplementationWorkflow.installGlobally(home: root)
        XCTAssertTrue(ImplementationWorkflow.globallyAvailable(home: root))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".claude/skills/code-review/SKILL.md")), "User's own review")
        let claude = try String(contentsOf: root.appendingPathComponent(".claude/skills/implement/SKILL.md"))
        XCTAssertTrue(claude.contains("Call the Skill tool with \"tdd\""))
        let codex = try String(contentsOf: root.appendingPathComponent(".agents/skills/implement/SKILL.md"))
        XCTAssertTrue(codex.contains("Read and apply the original Matt Pocock skill"))
        XCTAssertTrue(codex.contains(ImplementationWorkflow.revision))
        for name in ImplementationWorkflow.skills {
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: root.appendingPathComponent(".agents/skills/" + name + "/SKILL.md").path))
        }

        let broken = root.appendingPathComponent(".agents/skills/tdd")
        try FileManager.default.removeItem(at: broken)
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("missing-skill"))
        try ImplementationWorkflow.installGlobally(home: root)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: broken.appendingPathComponent("SKILL.md").path))
    }
}
