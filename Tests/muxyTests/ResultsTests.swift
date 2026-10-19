import XCTest
@testable import muxy

/// Parsers of the agents' logs, against small hand-written fixtures
/// shaped like real Claude Code and Codex files (Tests/Fixtures).
final class ResultsTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try XCTUnwrap(Transcripts.tail(of: url.path))
    }

    func testClaudeTurn() throws {
        let turn = Transcripts.claudeTurn(try fixture("claude-turn.jsonl"))
        XCTAssertEqual(turn.tests, TestRun(command: "cd app && CI=1 npm test", outcome: .passed))
        let summary = try XCTUnwrap(turn.summary.map(PlainText.from))
        XCTAssertEqual(summary, "Summary: Fixed the login redirect, added a test. Updated auth.ts. Added docs. All tests pass.")
    }

    func testClaudeFailingAndBackgroundTests() {
        func turn(_ result: String, background: Bool = false) -> TurnRecord {
            Transcripts.claudeTurn([
                #"{"type":"user","message":{"role":"user","content":"go"}}"#,
                #"{"type":"assistant","message":{"id":"a","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"go test ./...","run_in_background":\#(background)}}]}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t",\#(result)}]}}"#,
            ])
        }
        XCTAssertEqual(turn(#""content":"Exit code 1","is_error":true"#).tests?.outcome, .failed)
        XCTAssertEqual(turn(#""content":"Command running in background with ID: b1","is_error":false"#, background: true).tests?.outcome, .unclear)
        XCTAssertNil(turn(#""content":"ok""#).summary)

        // A compaction's summary is not a new prompt: the words before it count.
        let compacted = Transcripts.claudeTurn([
            #"{"type":"user","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"Finished."}]}}"#,
            #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued"}}"#,
        ])
        XCTAssertEqual(compacted.summary, "Finished.")
    }

    func testCodexTurn() throws {
        let turn = Transcripts.codexTurn(try fixture("codex-rollout.jsonl"))
        XCTAssertEqual(turn.tests, TestRun(command: "cargo test --all", outcome: .failed))
        XCTAssertEqual(turn.summary.map(PlainText.from), "Fixed the parser. One test still fails: parse_empty.")
    }

    func testCodexOlderFormats() throws {
        let old = Transcripts.codexTurn(try fixture("codex-rollout-old.jsonl"))
        XCTAssertEqual(old.tests, TestRun(command: "python -m pytest -q", outcome: .passed))
        // The final answer wins over a later commentary, before task_complete exists.
        XCTAssertEqual(old.summary, "Done: all three tests pass.")

        let shell = Transcripts.codexTurn(try fixture("codex-rollout-shell.jsonl"))
        XCTAssertEqual(shell.tests, TestRun(command: "make test", outcome: .failed))
        XCTAssertEqual(shell.summary, "make test fails in two places.")
    }

    func testTailDropsTheCutLine() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("muxy-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try (String(repeating: "x", count: 100) + "\n{\"a\":1}\n{\"b\":2}\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Transcripts.tail(of: file.path, limit: 20), [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(Transcripts.tail(of: file.path)?.count, 3)
        XCTAssertNil(Transcripts.tail(of: "/nonexistent/muxy.jsonl"))
    }

    func testTestCommands() {
        let tests = [
            "swift test", "go test ./...", "cd backend && go test -race ./...", "npm test", "npm run test:unit",
            "pnpm test", "yarn test --watch=false", "bun test", "npx vitest run", "pytest -q", "python3 -m pytest tests",
            "uv run pytest", "cargo test", "cargo nextest run", "./gradlew test", "mvn -q verify", "make test",
            "xcodebuild -scheme App test", "bundle exec rspec", "CI=1 FOO='a b' npm test", "timeout 600 swift test",
            "(cd app && npx jest)", "dotnet test", "set -o pipefail; go test ./... | tail -5",
        ]
        for command in tests {
            XCTAssertEqual(Transcripts.testKind(command), .plain, command)
        }
        XCTAssertEqual(Transcripts.testKind("go test ./... 2>&1 | tail -20"), .piped)
        let others = [
            "git status", "grep -rn test src", "cat test.txt", "npm install vitest", "swift build",
            "ls tests/", "echo npm test", "gh pr checks", "go vet ./...", "rg 'pytest'",
        ]
        for command in others {
            XCTAssertNil(Transcripts.testKind(command), command)
        }
    }

    func testPlainText() {
        XCTAssertEqual(PlainText.from("Done.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n> quoted *text*"), "Done. quoted text")
        XCTAssertEqual(PlainText.from("1. First\n2. Second step!"), "First. Second step!")
        XCTAssertFalse(PlainText.from("A — B").contains("—"))
        let long = String(repeating: "Word ", count: 50) + "end."
        XCTAssertLessThanOrEqual(PlainText.shortened(long, to: 40).count, 42)
        XCTAssertTrue(PlainText.shortened(long, to: 40).hasSuffix("…"))
        XCTAssertEqual(PlainText.shortened("First sentence here. Second one is longer than the limit.", to: 30), "First sentence here.")
        XCTAssertEqual(PlainText.shortened("Short.", to: 30), "Short.")
    }

    func testShortstat() {
        XCTAssertEqual(DiffCount.parse(shortstat: " 3 files changed, 10 insertions(+), 2 deletions(-)"),
                       DiffCount(files: 3, insertions: 10, deletions: 2))
        XCTAssertEqual(DiffCount.parse(shortstat: " 1 file changed, 1 deletion(-)"), DiffCount(files: 1, insertions: 0, deletions: 1))
        XCTAssertEqual(DiffCount.parse(shortstat: ""), DiffCount(files: 0, insertions: 0, deletions: 0))
    }

    func testPullRequestChecks() {
        let json: [String: Any] = [
            "number": 7, "state": "OPEN", "url": "https://github.com/o/r/pull/7",
            "statusCheckRollup": [
                ["__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"],
                ["__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"],
                ["__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"],
                ["__typename": "CheckRun", "name": "skip", "status": "COMPLETED", "conclusion": "SKIPPED"],
                ["__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR"],
            ],
        ]
        let pr = Results.pullRequest(from: json)
        XCTAssertEqual(pr?.checks, .failed)
        XCTAssertEqual(pr?.failing, ["lint", "ci/legacy"])
        XCTAssertEqual(pr?.checksURL, "https://github.com/o/r/pull/7/checks")
        XCTAssertNil(Results.pullRequest(from: ["state": "OPEN"]))
    }

    func testDiffCountsAgainstTheStartPoint() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("muxy-diff-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        func git(_ args: String...) {
            XCTAssertEqual(Shell.execute("/usr/bin/git", ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, in: repo).status, 0, args.joined(separator: " "))
        }
        git("init", "-q")
        try "a\nb\n".write(toFile: repo + "/one.txt", atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "start")
        // A commit, an uncommitted edit and a new file: three files.
        try "a\nb\nc\n".write(toFile: repo + "/one.txt", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: repo + "/two.txt", atomically: true, encoding: .utf8)
        git("add", "two.txt")
        git("commit", "-q", "-m", "work")
        try "a\n".write(toFile: repo + "/one.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/three.txt", atomically: true, encoding: .utf8)
        let count = try XCTUnwrap(Results.diff(in: repo, root: repo))
        // No origin: the start point is HEAD, so the commit doesn't count.
        XCTAssertEqual(count.files, 2)
        XCTAssertEqual(count.deletions, 1)
    }

    /// Read-only, against GitHub: MUXY_LIVE_GH=1 swift test --filter LivePR
    func testLivePRChecks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUXY_LIVE_GH"] != nil)
        let gh = try XCTUnwrap(Shell.find("gh"))
        let list = Shell.execute(gh, ["pr", "list", "--repo", "cli/cli", "--limit", "1", "--json", "number", "-q", ".[0].number"],
                                 in: NSTemporaryDirectory())
        let number = try XCTUnwrap(Int(list.output))
        let view = Shell.execute(gh, ["pr", "view", String(number), "--repo", "cli/cli", "--json", "number,state,url,statusCheckRollup"],
                                 in: NSTemporaryDirectory())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(view.output.utf8)) as? [String: Any])
        let pr = try XCTUnwrap(Results.pullRequest(from: json))
        XCTAssertEqual(pr.number, number)
        XCTAssertTrue(pr.url.hasSuffix("/pull/\(number)"))
        print("[live] #\(pr.number) \(pr.checks) failing: \(pr.failing)")
    }

    /// Read-only, this machine's newest real logs: MUXY_REAL_LOGS=1 swift test --filter RealLogs
    func testRealLogsDontTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUXY_REAL_LOGS"] != nil)
        for (pattern, codex) in [("/.claude/projects", false), ("/.codex/sessions", true)] {
            let root = Paths.home + pattern
            let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? [])
                .filter { $0.hasSuffix(".jsonl") && (!codex || $0.contains("rollout-")) }
                .map { root + "/" + $0 }
                .sorted { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date ?? .distantPast)
                    ?? .distantPast > (try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate] as? Date ?? .distantPast) ?? .distantPast }
                .prefix(15)
            var summaries = 0
            for file in files {
                let lines = try XCTUnwrap(Transcripts.tail(of: file))
                let turn = codex ? Transcripts.codexTurn(lines) : Transcripts.claudeTurn(lines)
                if turn.summary != nil { summaries += 1 }
                print("[real] \(turn.summary.map { PlainText.shortened(PlainText.from($0), to: 160) } ?? "-") \(codex ? "codex" : "claude") summary:\(turn.summary != nil) tests:\(String(describing: turn.tests?.outcome)) \(turn.tests.map { String($0.command.prefix(70)) } ?? "") \((file as NSString).lastPathComponent)")
            }
            XCTAssertGreaterThan(summaries, 0, pattern)
        }
    }
}
