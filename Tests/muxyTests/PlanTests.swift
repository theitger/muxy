import XCTest
@testable import muxy

final class PlanTests: XCTestCase {
    func testClaudePlansInItsPlanModeWithoutAnySkippedPermissions() {
        // Even only allowed, skipped permissions make plan mode go on without the go-ahead.
        XCTAssertEqual(AgentKind.claude.command(.new(prompt: true, id: "abc"), skipPermissions: true, plan: true),
                       #"claude --permission-mode plan --session-id abc "$MUXY_PROMPT""#)
        // The go-ahead: the same conversation, permissions skipped, told to go.
        XCTAssertEqual(AgentKind.claude.command(.resume(id: "abc"), skipPermissions: true, resumePrompt: true),
                       #"claude --dangerously-skip-permissions --resume abc "$MUXY_PROMPT""#)
        XCTAssertEqual(AgentKind.claude.command(.new(prompt: true, id: "abc"), skipPermissions: false, plan: true),
                       #"claude --permission-mode plan --session-id abc "$MUXY_PROMPT""#)
        // Without a plan nothing changes.
        XCTAssertEqual(AgentKind.claude.command(.new(prompt: true, id: "abc"), skipPermissions: true),
                       #"claude --dangerously-skip-permissions --session-id abc "$MUXY_PROMPT""#)
        // Codex has no plan mode: its prompt asks for the plan.
        XCTAssertEqual(AgentKind.codex.command(.new(prompt: true, id: nil), skipPermissions: false, plan: true),
                       #"codex "$MUXY_PROMPT""#)
        XCTAssertTrue(Flow.planNote.contains("Change no files"))
    }

    func testTheQueueHoldsAReadyPlanForYouWithoutASlot() {
        var item = Queue.Item(issue: Issue(repo: "o/r", number: 1, title: "t", url: "", state: "OPEN"), agent: .claude)
        item.phase = .running
        item.plan = true
        let facts = Queue.Facts(step: .approvePlan, agent: .blocked, idleSince: nil, hasPR: false, quorumInstalled: true, merged: false)
        XCTAssertEqual(Queue.decide(item, facts: facts, now: Date()), .finish(.planReady))
        XCTAssertFalse(Queue.Phase.planReady.isActive, "it holds no slot")
        XCTAssertFalse(Queue.Phase.planReady.isFinished, "and isn't done")
        XCTAssertEqual(NextStep.approvePlan.stage, .working)
    }

    func testAQueueItemFromBeforePlansStillReads() throws {
        // Saved by 0.7: no "plan" key.
        let old = #"[{"issue":{"repo":"o/r","number":1,"title":"t","url":"","state":"OPEN","labels":[]},"agent":"claude","phase":{"queued":{}},"sawWork":false,"askedForPR":false,"babysits":0}]"#
        let items = try JSONDecoder().decode([Queue.Item].self, from: Data(old.utf8))
        XCTAssertNil(items.first?.plan)
    }
}

final class PromptFieldTests: XCTestCase {
    private let issue = Issue(repo: "o/r", number: 9, title: "Fix it", url: "u", state: "OPEN", body: "The body.")

    func testTheDefaultPromptIsTheIssueAndNothingElse() {
        let claude = Issues.prompt(for: issue, localRepo: "o/r", template: Issues.defaultTemplate, implement: true)
        XCTAssertEqual(claude, "/implement #9: Fix it\n\nThe body.")
        let plain = Issues.prompt(for: issue, localRepo: "o/r", template: Issues.defaultTemplate)
        XCTAssertEqual(plain, "#9: Fix it\n\nThe body.")

        let queued = Issues.prompt(for: issue, localRepo: "o/r", template: Issues.defaultTemplate, plan: true, unattended: true)
        XCTAssertTrue(queued.hasPrefix("#9: Fix it\n\nThe body.\n\n"))
        XCTAssertTrue(queued.contains(Flow.planNote))
        XCTAssertTrue(queued.hasSuffix(Queue.unattendedNote))
    }

    func testAnOwnTemplateDecidesAboutImplementButKeepsWhatPlanAndQueueNeed() {
        let own = "{title}: do it."
        XCTAssertEqual(Issues.prompt(for: issue, template: own, implement: true), "Fix it: do it.", "no {implement}, no /implement")
        let queued = Issues.prompt(for: issue, template: own, plan: true, unattended: true)
        XCTAssertTrue(queued.hasPrefix("Fix it: do it."))
        XCTAssertTrue(queued.contains(Flow.planNote))
        XCTAssertTrue(queued.contains(Queue.unattendedNote))
    }
}
