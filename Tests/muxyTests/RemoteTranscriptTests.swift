import XCTest
@testable import muxy

/// The phone's chat, read from either agent's log (Remote/Transcript.swift).
final class RemoteTranscriptTests: XCTestCase {
    func testCodexRolloutBecomesAConversation() throws {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"x","cwd":"/tmp"}}"#,
            ##"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"# AGENTS.md instructions for /tmp"}]}}}"##,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"Fix the login"}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","content":[{"type":"Text","text":"Looking at it."}],"phase":"commentary"}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"e1","command":["/bin/zsh","-c","swift test"],"aggregated_output":"ok\n","exit_code":1}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"f1","status":"completed","changes":{"/tmp/a.swift":{"type":"update","unified_diff":"@@ -1 +1 @@\n-old\n+new\n"}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Looking at it."}}"#,
        ]
        let items = Transcript.items(at: try write(lines))
        XCTAssertEqual(items.map { $0["kind"] as? String }, ["user", "agent", "tool", "tool"])
        XCTAssertEqual(items[0]["text"] as? String, "Fix the login")
        XCTAssertEqual(items[2]["target"] as? String, "swift test")
        XCTAssertEqual(items[2]["error"] as? Bool, true)
        let diff = try XCTUnwrap(items[3]["diff"] as? [[String: String]])
        XCTAssertEqual(diff.map { $0["sign"]! + $0["text"]! }, ["-old", "+new"])
    }

    /// Older Codex versions: loose events only.
    func testOlderCodexEvents() throws {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Run it"}}"#,
            #"{"type":"event_msg","payload":{"type":"exec_command_end","call_id":"c","command":["bash","-lc","make"],"aggregated_output":"done","exit_code":0}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Built."}}"#,
        ]
        let items = Transcript.items(at: try write(lines))
        XCTAssertEqual(items.map { $0["kind"] as? String }, ["user", "tool", "agent"])
        XCTAssertEqual(items[1]["target"] as? String, "make")
    }

    func testClaudeLogStillReads() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Add a test"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
        ]
        let items = Transcript.items(at: try write(lines))
        XCTAssertEqual(items.map { $0["kind"] as? String }, ["user", "agent", "tool"])
        XCTAssertEqual(items[2]["done"] as? Bool, true)
    }

    private func write(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muxy-transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
