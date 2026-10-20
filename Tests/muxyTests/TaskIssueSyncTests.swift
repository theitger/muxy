import XCTest
@testable import muxy

final class TaskIssueSyncTests: XCTestCase {
    private func issue(_ title: String = "New title", body: String = "- [ ] New check") -> Issue {
        Issue(repo: "owner/repo", number: 7, title: title, url: "https://github.com/owner/repo/issues/7", state: "OPEN", body: body)
    }

    func testUpdatesTitleBodyAndImportedCriteriaButKeepsLocalWork() {
        var record = TaskRecord()
        record.synchronize(issue("Old title", body: "- [ ] Keep\n- [ ] Remove"), previousTitle: "Old title")
        record.criteria[0].checkedHead = "head"
        let kept = record.criteria[0].id
        record.criteria.append(TaskCriterion(text: "My own check", checkedHead: "head"))
        record.synchronize(issue(body: "Updated description\n- [x] Keep\n- [ ] New check"), previousTitle: "Old title")
        XCTAssertEqual(record.goal, "New title")
        XCTAssertEqual(record.issueTitle, "New title")
        XCTAssertEqual(record.issueBody, "Updated description\n- [x] Keep\n- [ ] New check")
        XCTAssertEqual(record.criteria.map(\.text), ["Keep", "New check", "My own check"])
        XCTAssertEqual(record.criteria[0].id, kept)
        XCTAssertTrue(record.criteria[0].checked(at: "head"))
        XCTAssertFalse(record.criteria[1].checked(at: "head"))
        let saved = record
        record.synchronize(issue(body: "Updated description\n- [x] Keep\n- [ ] New check"), previousTitle: "New title")
        XCTAssertEqual(record, saved)
    }

    func testPreservesCustomGoalAndEditorDeletedCriteriaAcrossRefresh() {
        var record = TaskRecord()
        record.goal = "Custom goal"
        record.customGoal = true
        record.synchronize(issue(), previousTitle: "Old title")
        record.removeCriterion(record.criteria[0])
        record.synchronize(issue(), previousTitle: "New title")
        XCTAssertEqual(record.goal, "Custom goal")
        XCTAssertTrue(record.criteria.isEmpty)
    }

    func testMigratesEarlierImportsAndPreservesEarlierCustomGoal() throws {
        let json = """
        {"goal":"My own goal","criteriaImported":true,"issueBody":"- [ ] Old","criteria":[{"id":"00000000-0000-0000-0000-000000000001","text":"Old"},{"id":"00000000-0000-0000-0000-000000000002","text":"Local"}],"feedback":[],"draft":""}
        """
        var record = try JSONDecoder().decode(TaskRecord.self, from: Data(json.utf8))
        record.synchronize(issue(), previousTitle: "Old title")
        XCTAssertEqual(record.goal, "My own goal")
        XCTAssertEqual(record.criteria.map(\.text), ["New check", "Local"])
        let restored = try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
    }

    func testGitHubCheckedBoxesNeverApproveChangedCriteria() {
        var record = TaskRecord()
        record.synchronize(issue(body: "- [x] Check"), previousTitle: "Old")
        record.criteria[0].checkedHead = "head"
        record.synchronize(issue(body: "- [x] Changed check\n- [ ] Changed check"), previousTitle: "New title")
        XCTAssertEqual(record.criteria.count, 1)
        XCTAssertFalse(record.satisfied(at: "head"))
    }

    func testDefaultAgentUsesSettingAndMigratesEarlierPreference() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AgentKind.preferred(in: defaults), .claude)
        defaults.set("codex", forKey: "newSessionAgent")
        XCTAssertEqual(AgentKind.preferred(in: defaults), .codex)
        defaults.set("claude", forKey: AgentKind.defaultKey)
        XCTAssertEqual(AgentKind.preferred(in: defaults), .claude)
        defaults.set("invalid", forKey: AgentKind.defaultKey)
        XCTAssertEqual(AgentKind.preferred(in: defaults), .claude)
    }
}
