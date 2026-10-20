import XCTest
@testable import muxy

final class IssuesTests: XCTestCase {
    func testNewSessionIssuePromptIncludesSavedTaskInstructions() {
        let issue = Issue(repo: "o/r", number: 9, title: "Crash on start", url: "", state: "OPEN")
        let prompt = NewSessionView.issuePrompt(for: issue, note: "", localRepo: "o/r", agent: .codex,
                                                implement: false, instructions: "User's task goal:\nPreserve the recovery flow")
        XCTAssertTrue(prompt.contains("Crash on start"))
        XCTAssertTrue(prompt.contains("Preserve the recovery flow"))
    }

    func testReferences() {
        XCTAssertEqual(IssueRef.parse("#123"), IssueRef(repo: nil, number: 123))
        XCTAssertEqual(IssueRef.parse("  42 "), IssueRef(repo: nil, number: 42))
        XCTAssertEqual(IssueRef.parse("cli/cli#7"), IssueRef(repo: "cli/cli", number: 7))
        XCTAssertEqual(
            IssueRef.parse("https://github.com/Owner/Repo/issues/99#issuecomment-1"),
            IssueRef(repo: "Owner/Repo", number: 99)
        )
        XCTAssertEqual(
            IssueRef.parse("https://git.example.com/team/app/issues/5"),
            IssueRef(repo: "git.example.com/team/app", number: 5)
        )
        XCTAssertEqual(IssueRef.parse("#12 keep the old API"), IssueRef(repo: nil, number: 12, note: "keep the old API"))
    }

    func testNotReferences() {
        // A number with words after it is a sentence, not an issue.
        XCTAssertNil(IssueRef.parse("123 tests are failing"))
        XCTAssertNil(IssueRef.parse("fix #12"))
        XCTAssertNil(IssueRef.parse("https://github.com/o/r/pull/3"))
        XCTAssertNil(IssueRef.parse("#"))
        XCTAssertNil(IssueRef.parse("#0"))
        XCTAssertNil(IssueRef.parse("0"))
        XCTAssertNil(IssueRef.parse(""))
        XCTAssertNil(IssueRef.parse("12345678"))
    }

    func testRemoteSlugs() {
        XCTAssertEqual(Issues.slug(ofRemote: "git@github.com:theitger/muxy.git"), "theitger/muxy")
        XCTAssertEqual(Issues.slug(ofRemote: "https://github.com/theitger/muxy"), "theitger/muxy")
        XCTAssertEqual(Issues.slug(ofRemote: "https://user@github.com/theitger/muxy.git/"), "theitger/muxy")
        XCTAssertEqual(Issues.slug(ofRemote: "ssh://git@github.com:22/theitger/muxy.git"), "theitger/muxy")
        XCTAssertEqual(Issues.slug(ofRemote: "git@gitlab.example.com:team/app.git"), "gitlab.example.com/team/app")
        XCTAssertNil(Issues.slug(ofRemote: "/Users/me/repos/local.git"))
        XCTAssertNil(Issues.slug(ofRemote: "https://example.com/a/b/c"))
    }

    func testBranchName() {
        let issue = Issue(repo: "o/r", number: 123, title: "Fix the Login-Redirect für Ümlaut users!", url: "", state: "OPEN")
        XCTAssertEqual(Issues.branchName(for: issue), "123-fix-the-login-redirect-fur-umlaut")
        let empty = Issue(repo: "o/r", number: 7, title: "日本語", url: "", state: "OPEN")
        XCTAssertEqual(Issues.branchName(for: empty), "7-issue")
        let long = Issue(repo: "o/r", number: 1, title: String(repeating: "abcdefghij ", count: 10), url: "", state: "OPEN")
        XCTAssertLessThanOrEqual(Issues.branchName(for: long).count, 50)
    }

    func testPromptIsTheSameForEveryAgent() {
        let issue = Issue(
            repo: "o/r", number: 9, title: "Crash on start", url: "https://github.com/o/r/issues/9",
            state: "OPEN", labels: ["bug"], body: "Steps:\n1. open"
        )
        let prompt = Issues.prompt(for: issue, localRepo: "o/r")
        XCTAssertEqual(prompt, "#9: Crash on start\n\nSteps:\n1. open")
        // Another repository's issue is referenced in full.
        XCTAssertTrue(Issues.prompt(for: issue, localRepo: "me/fork").hasPrefix("o/r#9: Crash on start"))
    }

    func testSavedSessionsWithoutIssueStillLoad() throws {
        let old = #"{"windows":[{"workspaces":[{"tabs":[{"directory":"/tmp","agent":"claude"}]}]}]}"#
        let state = try JSONDecoder().decode(SavedSessions.self, from: Data(old.utf8))
        XCTAssertNil(state.windows[0].workspaces[0].tabs[0].issue)
        var tab = state.windows[0].workspaces[0].tabs[0]
        tab.issue = Issue(repo: "o/r", number: 1, title: "t", url: "u", state: "OPEN", body: nil)
        let again = try JSONDecoder().decode(SavedSessions.Tab.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(again.issue?.number, 1)
    }

    /// Read-only, against GitHub: MUXY_LIVE_GH=1 swift test --filter Live
    func testLiveLookup() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUXY_LIVE_GH"] != nil)
        guard case let .found(issue) = Issues.view(2, repo: "cli/cli", in: NSTemporaryDirectory()) else {
            return XCTFail("cli/cli#2 not found")
        }
        XCTAssertEqual(issue.number, 2)
        XCTAssertEqual(issue.repo, "cli/cli")
        XCTAssertFalse(issue.isOpen)
        XCTAssertEqual(Issues.view(1, repo: "cli/cli", in: NSTemporaryDirectory()), .pullRequest)
        XCTAssertEqual(Issues.view(99_999_999, repo: "cli/cli", in: NSTemporaryDirectory()), .notFound)
        let list = try XCTUnwrap(Issues.list(repo: "cli/cli", in: NSTemporaryDirectory()))
        XCTAssertFalse(list.issues.isEmpty)
    }
}

final class PromptTemplateTests: XCTestCase {
    func testImplementIsOnlyExpandedForClaudeEvenWhenRepoHasTheSkill() {
        let issue = Issue(repo: "o/r", number: 9, title: "Fix it", url: "", state: "OPEN", body: "The task.")
        XCTAssertEqual(Issues.prompt(for: issue, template: Issues.defaultTemplate, agent: .claude, implement: true),
                       "/implement o/r#9: Fix it\n\nThe task.")
        for agent in [AgentKind.codex, nil] {
            XCTAssertEqual(Issues.prompt(for: issue, template: Issues.defaultTemplate, agent: agent, implement: true),
                           "o/r#9: Fix it\n\nThe task.")
        }
        XCTAssertEqual(Issues.prompt(for: issue, template: Issues.defaultTemplate, agent: .claude, implement: false),
                       "o/r#9: Fix it\n\nThe task.")
    }

    func testCustomTemplateAndEmptyFields() {
        let issue = Issue(repo: "o/r", number: 9, title: "Crash", url: "https://x/9", state: "OPEN", body: "Use {braces} here")
        let text = Issues.prompt(for: issue, localRepo: "o/r", template: "Plan first.\n\n{reference} {title}\n\n{labels}\n\n{body}\n\n{note}\n\nThen: Closes {reference}")
        XCTAssertEqual(text, "Plan first.\n\n#9 Crash\n\nUse {braces} here\n\nThen: Closes #9")
    }
}
