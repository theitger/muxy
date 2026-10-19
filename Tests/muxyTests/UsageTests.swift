import XCTest
@testable import muxy

final class UsageTests: XCTestCase {
    private func folder() throws -> String {
        let path = NSTemporaryDirectory() + "muxy-usage-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testReadsCodexsLimitsFromItsNewestSessionFile() throws {
        let home = try folder()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = String(format: "%@/sessions/%04d/%02d/%02d", home, parts.year!, parts.month!, parts.day!)
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        // As Codex writes it (one token_count event per line).
        let line = #"{"timestamp":"x","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":24.0,"window_minutes":10080,"resets_at":1792874462},"secondary":{"used_percent":61.5,"window_minutes":300,"resets_at":1792800000}}}}"#
        try ("{\"type\":\"session_meta\"}\n" + line + "\n").write(toFile: day + "/rollout-a.jsonl", atomically: true, encoding: .utf8)
        let windows = Usage.readCodex(home: home)
        XCTAssertEqual(windows.map(\.name), [L("week"), "5h"])
        XCTAssertEqual(windows.first?.used, 24)
        XCTAssertEqual(windows.first?.resets, Date(timeIntervalSince1970: 1792874462))
    }

    func testReadsClaudesLimitsFromTheStatusLineInput() throws {
        let file = try folder() + "/claude-status.json"
        try #"{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":34,"resets_at":1792800000},"seven_day":{"used_percentage":96.2,"resets_at":1793000000}}}"#
            .write(toFile: file, atomically: true, encoding: .utf8)
        let windows = Usage.readClaude(file: file)
        XCTAssertEqual(windows.map(\.used), [34, 96.2])
        XCTAssertEqual(Usage.readClaude(file: file + ".missing"), [])
    }

    func testTheStatusLineTapKeepsTheInputRunsYoursAndGivesItBackAsItWas() throws {
        let dir = try folder()
        let settings = URL(fileURLWithPath: dir + "/settings.json")
        let script = URL(fileURLWithPath: dir + "/tap.sh")
        let status = dir + "/state/claude-status.json"
        let original = """
        {
          "hooks": {},
          "statusLine": {
            "type": "command",
            "command": "echo \\"mine: $(cat)\\"",
            "padding": 0
          }
        }

        """
        try original.write(to: settings, atomically: true, encoding: .utf8)

        try ClaudeStatusTap.install(settings: settings, script: script, statusFile: status)
        XCTAssertTrue(ClaudeStatusTap.isInstalled(settings: settings, script: script))
        XCTAssertTrue(try String(contentsOf: settings, encoding: .utf8).contains("\"padding\": 0"), "the rest stays")

        // Claude runs the command with the JSON on stdin.
        let run = Shell.execute("/bin/sh", ["-c", "printf '%s' '{\"rate_limits\":{}}' | \(script.path)"], in: dir)
        XCTAssertEqual(run.output.trimmingCharacters(in: .whitespacesAndNewlines), #"mine: {"rate_limits":{}}"#,
                       "your status line still prints, with the same input")
        XCTAssertEqual(try String(contentsOfFile: status, encoding: .utf8), #"{"rate_limits":{}}"#)

        try ClaudeStatusTap.uninstall(settings: settings, script: script)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original, "byte for byte as before")
    }

    func testWithoutAStatusLineItTakesItsOwnOutAgain() throws {
        let dir = try folder()
        let settings = URL(fileURLWithPath: dir + "/settings.json")
        let script = URL(fileURLWithPath: dir + "/tap.sh")
        try "{\n  \"model\": \"opus\"\n}\n".write(to: settings, atomically: true, encoding: .utf8)
        try ClaudeStatusTap.install(settings: settings, script: script, statusFile: dir + "/s.json")
        try ClaudeStatusTap.uninstall(settings: settings, script: script)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}\n")
    }
}
