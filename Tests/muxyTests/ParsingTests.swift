import XCTest
@testable import muxy

@MainActor
final class HookParseTests: XCTestCase {
    func testNewFormat() throws {
        let event = try XCTUnwrap(HookWatcher.parse("S1 codex prompt abc-123 /Users/me/My Project/log.jsonl\n"))
        XCTAssertEqual(event.session, "S1")
        XCTAssertEqual(event.agent, "codex")
        XCTAssertEqual(event.name, "prompt")
        XCTAssertEqual(event.agentSession, "abc-123")
        XCTAssertEqual(event.transcript, "/Users/me/My Project/log.jsonl")
    }

    func testOldFormatWithSpacesInTranscript() throws {
        let event = try XCTUnwrap(HookWatcher.parse("S1 claude stop /Users/me/a b c/t.jsonl"))
        XCTAssertEqual(event.name, "stop")
        XCTAssertNil(event.agentSession)
        XCTAssertEqual(event.transcript, "/Users/me/a b c/t.jsonl")
    }

    func testDashesAndMissingFields() throws {
        let dashes = try XCTUnwrap(HookWatcher.parse("S1 claude notification - -"))
        XCTAssertEqual(dashes.name, "notification")
        XCTAssertNil(dashes.agentSession)
        XCTAssertNil(dashes.transcript)

        let idOnly = try XCTUnwrap(HookWatcher.parse("S1 claude prompt id-1 -"))
        XCTAssertEqual(idOnly.agentSession, "id-1")
        XCTAssertNil(idOnly.transcript)

        let bare = try XCTUnwrap(HookWatcher.parse("S1"))
        XCTAssertEqual(bare.agent, "claude")
        XCTAssertEqual(bare.name, "stop")
        XCTAssertNil(bare.agentSession)

        let dashAgent = try XCTUnwrap(HookWatcher.parse("S1 - - - /t.jsonl"))
        XCTAssertEqual(dashAgent.agent, "claude")
        XCTAssertEqual(dashAgent.name, "stop")
        XCTAssertEqual(dashAgent.transcript, "/t.jsonl")
    }

    func testEmptyIsNil() {
        XCTAssertNil(HookWatcher.parse(""))
        XCTAssertNil(HookWatcher.parse(" claude stop"))
        XCTAssertNil(HookWatcher.parse("\n"))
    }
}

final class AgentCommandTests: XCTestCase {
    override func setUp() {
        unsetenv("MUXY_DEBUG_AGENT")
    }

    func testClaude() {
        let claude = AgentKind.claude
        XCTAssertEqual(claude.command(.new(prompt: true, id: "0b1c-2d"), skipPermissions: false),
                       #"claude --session-id 0b1c-2d "$MUXY_PROMPT""#)
        XCTAssertEqual(claude.command(.new(prompt: false, id: nil), skipPermissions: true),
                       "claude --dangerously-skip-permissions")
        XCTAssertEqual(claude.command(.resume(id: "abc"), skipPermissions: false), "claude --resume abc")
        XCTAssertEqual(claude.command(.resume(id: nil), skipPermissions: true),
                       "claude --dangerously-skip-permissions --continue")
    }

    func testCodex() {
        let codex = AgentKind.codex
        // Codex picks its own id: none is passed for a new one.
        XCTAssertEqual(codex.command(.new(prompt: true, id: "abc"), skipPermissions: false), #"codex "$MUXY_PROMPT""#)
        XCTAssertEqual(codex.command(.new(prompt: false, id: nil), skipPermissions: true),
                       "codex --dangerously-bypass-approvals-and-sandbox")
        XCTAssertEqual(codex.command(.resume(id: "019a-77"), skipPermissions: false), "codex resume 019a-77")
        XCTAssertEqual(codex.command(.resume(id: nil), skipPermissions: true),
                       "codex resume --dangerously-bypass-approvals-and-sandbox --last")
    }

    func testUnsafeIdsNeverReachTheCommandLine() {
        let hostile = ["x; rm -rf ~", "$(whoami)", "`id`", "a b", "a'b", "a\"b", "a\nb", "", "--yolo|sh",
                       String(repeating: "a", count: 129)]
        for id in hostile {
            XCTAssertEqual(AgentKind.claude.command(.resume(id: id), skipPermissions: false), "claude --continue", id)
            XCTAssertEqual(AgentKind.codex.command(.resume(id: id), skipPermissions: false), "codex resume --last", id)
            XCTAssertEqual(AgentKind.claude.command(.new(prompt: false, id: id), skipPermissions: false), "claude", id)
        }
    }

    func testRecognisedFromCommandLine() {
        XCTAssertEqual(AgentKind(commandLine: "claude --resume x"), .claude)
        XCTAssertEqual(AgentKind(commandLine: "/opt/homebrew/bin/codex"), .codex)
        XCTAssertNil(AgentKind(commandLine: "vim claude"))
        XCTAssertNil(AgentKind(commandLine: ""))
    }
}

@MainActor
final class SavedSessionsTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let saved = SavedSessions(windows: [
            .init(workspaces: [
                .init(tabs: [
                    .init(directory: "/a b/c", agent: "claude", conversation: "id-1", skipPermissions: true),
                    .init(directory: "/x", agent: nil, conversation: nil, skipPermissions: nil),
                ], selected: 1),
            ], selected: 0),
            .init(workspaces: [], selected: nil),
        ])
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(SavedSessions.self, from: data), saved)
    }

    func testOlderFileWithoutOptionalFieldsDecodes() throws {
        let json = #"{"windows":[{"workspaces":[{"tabs":[{"directory":"/x"}]}]}]}"#
        let saved = try JSONDecoder().decode(SavedSessions.self, from: Data(json.utf8))
        XCTAssertEqual(saved.windows.first?.workspaces.first?.tabs.first?.directory, "/x")
        XCTAssertNil(saved.windows.first?.selected)
    }

    func testTabWithMissingFolderComesBackAsNothing() throws {
        let gone = SavedSessions.Tab(directory: "/nonexistent/\(UUID().uuidString)", agent: "claude",
                                     conversation: "id", skipPermissions: false)
        XCTAssertNil(gone.session())
        // A file where the folder was isn't a folder either.
        let repo = try TempRepo()
        let file = SavedSessions.Tab(directory: repo.path("README.md"), agent: nil, conversation: nil, skipPermissions: nil)
        XCTAssertNil(file.session())
    }
}

final class PullRequestLookupTests: XCTestCase {
    private func lookup(_ status: Int32, _ output: String = "", _ error: String = "") -> Git.Lookup {
        Git.lookup(from: Shell.Result(status: status, output: output, error: error))
    }

    private func found(_ json: String) throws -> Git.PullRequest {
        guard case let .found(pr) = lookup(0, json) else {
            XCTFail("expected a PR for \(json)")
            throw TempRepo.Failure(description: "no PR")
        }
        return pr
    }

    func testMergedClosedOpen() throws {
        let merged = try found(#"{"number":12,"state":"MERGED","headRefOid":"abc","isDraft":false,"#
            + #""mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","reviewDecision":"","statusCheckRollup":[]}"#)
        XCTAssertEqual(merged.number, 12)
        XCTAssertEqual(merged.state, .merged)
        XCTAssertEqual(merged.head, "abc")
        XCTAssertEqual(merged.checks, .none)

        XCTAssertEqual(try found(#"{"number":3,"state":"CLOSED"}"#).state, .closed)

        let open = try found(#"{"number":4,"state":"OPEN","isDraft":true,"mergeable":"MERGEABLE","#
            + #""mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED","#
            + #""statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"IN_PROGRESS"}]}"#)
        XCTAssertEqual(open.state, .open)
        XCTAssertTrue(open.isDraft)
        XCTAssertEqual(open.mergeability, .reviewRequired)
        XCTAssertEqual(open.checks, .pending)
        XCTAssertNil(open.head)
    }

    func testNoPullRequest() {
        // gh 2.101 says it capitalised; older ones in lower case.
        for message in [#"no pull requests found for branch "feat/x""#, #"No pull requests found for branch "feat/x""#] {
            guard case .none = lookup(1, "", message) else { return XCTFail(message) }
        }
    }

    func testOtherFailuresAreUnknown() {
        for (status, output, error) in [
            (Int32(1), "", "error connecting to api.github.com"),
            (1, "", "HTTP 403: API rate limit exceeded"),
            (-1, "", ""),
            (0, "not json", ""),
            (0, #"{"state":"OPEN"}"#, ""),
            (0, "[]", ""),
        ] {
            guard case .unknown = lookup(status, output, error) else { return XCTFail("\(status) \(output) \(error)") }
        }
    }

    func testChecks() {
        XCTAssertEqual(Git.checks(from: [["state": "SUCCESS"], ["conclusion": "FAILURE", "status": "COMPLETED"]]), .failed)
        XCTAssertEqual(Git.checks(from: [["state": "PENDING"]]), .pending)
        XCTAssertEqual(Git.checks(from: [["state": "SUCCESS"], ["status": "COMPLETED", "conclusion": "SKIPPED"]]), .passed)
    }

    func testMergeability() {
        XCTAssertEqual(Git.mergeability(mergeable: "CONFLICTING", state: "CLEAN", review: ""), .conflicting)
        XCTAssertEqual(Git.mergeability(mergeable: "MERGEABLE", state: "BEHIND", review: ""), .behind)
        XCTAssertEqual(Git.mergeability(mergeable: "MERGEABLE", state: "BLOCKED", review: "CHANGES_REQUESTED"),
                       .changesRequested)
        XCTAssertEqual(Git.mergeability(mergeable: "MERGEABLE", state: "UNSTABLE", review: ""), .clean)
        XCTAssertEqual(Git.mergeability(mergeable: "UNKNOWN", state: "UNKNOWN", review: ""), .unknown)
    }
}

final class BranchNamerTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(BranchNamer.normalize("feat/add-login"), "feat/add-login")
        XCTAssertEqual(BranchNamer.normalize("Fix Login Bug"), "fix/login-bug")
        XCTAssertEqual(BranchNamer.normalize("Add Login Page"), "feat/add-login-page")
        XCTAssertEqual(BranchNamer.normalize("fix-login-bug"), "fix/login-bug")
        XCTAssertEqual(BranchNamer.normalize("`fix/42_Login Bug.`"), "fix/42-login-bug")
        XCTAssertEqual(BranchNamer.normalize("Here you go:\n\nchore/bump-deps\n"), "chore/bump-deps")
        XCTAssertEqual(BranchNamer.normalize("feat/über--naïve"), "feat/ber-nave")
        XCTAssertEqual(BranchNamer.normalize("x; rm -rf ~ $(id)"), "feat/x-rm-rf-id")
        XCTAssertLessThanOrEqual(BranchNamer.normalize(String(repeating: "word-", count: 40))?.count ?? 0, 60)
    }

    func testNormalizeRejectsAnswersWithoutWords() {
        for answer in ["", "   ", ".", "```", "feat/", "fix/---", "!!!"] {
            XCTAssertNil(BranchNamer.normalize(answer), answer)
        }
    }

    func testNormalizeFindsTheNameInsideAFence() {
        XCTAssertEqual(BranchNamer.normalize("```\nfix/login-bug\n```"), "fix/login-bug")
        XCTAssertEqual(BranchNamer.normalize("**fix/login-bug**"), "fix/login-bug")
    }

    func testIssueNumber() {
        XCTAssertEqual(BranchNamer.issueNumber(in: "gh issue 42 implement"), 42)
        XCTAssertEqual(BranchNamer.issueNumber(in: "fix #7 please"), 7)
        XCTAssertEqual(BranchNamer.issueNumber(in: "see https://github.com/a/b/issues/314 and #2"), 314)
        XCTAssertEqual(BranchNamer.issueNumber(in: "Issue #9: crash"), 9)
        XCTAssertNil(BranchNamer.issueNumber(in: "make it &#39;quoted&#39;"))
        XCTAssertNil(BranchNamer.issueNumber(in: "no number here"))
    }

    func testPlaceholder() {
        let name = BranchNamer.placeholder(now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(BranchNamer.isPlaceholder(name))
        XCTAssertTrue(name.range(of: #"^session/\d{4}-\d{6}$"#, options: .regularExpression) != nil, name)
        XCTAssertFalse(BranchNamer.isPlaceholder("feat/session"))
    }

    func testRenameOnlyWhileUnpushed() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let worktree = try repo.addWorktree("session-1", branch: "session/0101-000000")
        try repo.git("branch", "feat/taken")
        XCTAssertEqual(BranchNamer.rename(in: worktree, from: "session/0101-000000", to: "feat/taken"), "feat/taken-2")
        XCTAssertEqual(try repo.git("branch", "--show-current", in: worktree), "feat/taken-2")

        let pushed = try repo.addWorktree("session-2", branch: "session/0202-000000")
        try repo.git("push", "--quiet", "origin", "session/0202-000000", in: pushed)
        XCTAssertNil(BranchNamer.rename(in: pushed, from: "session/0202-000000", to: "feat/y"))
        XCTAssertNil(BranchNamer.rename(in: pushed, from: "session/other", to: "feat/y"), "not on that branch")
    }
}
