import XCTest
@testable import muxy

final class QueueTests: XCTestCase {
    private let now = Date()
    private let issue = Issue(repo: "o/r", number: 7, title: "Fix it", url: "", state: "OPEN")

    private func item(acted: TimeInterval? = nil, started: TimeInterval = -600, askedForPR: Bool = false, babysits: Int = 0) -> Queue.Item {
        var item = Queue.Item(issue: issue, agent: .claude)
        item.phase = .running
        item.started = now.addingTimeInterval(started)
        item.acted = acted.map { now.addingTimeInterval($0) }
        item.askedForPR = askedForPR
        item.babysits = babysits
        return item
    }

    private func facts(_ step: NextStep, agent: AgentState = .idle, idle: TimeInterval? = nil, hasPR: Bool = false,
                       quorum: Bool = true, merged: Bool = false) -> Queue.Facts {
        Queue.Facts(step: step, agent: agent, idleSince: idle.map { now.addingTimeInterval($0) }, hasPR: hasPR,
                    quorumInstalled: quorum, merged: merged)
    }

    func testWorkingAgentIsLeftAlone() {
        XCTAssertEqual(Queue.decide(item(), facts: facts(.wait("Working"), agent: .working), now: now), .wait)
    }

    func testAFinishedTurnGetsItsPullRequestOnceThenItsYours() {
        XCTAssertEqual(Queue.decide(item(), facts: facts(.openPR, idle: -120), now: now), .askForPR)
        // Just asked: give the agent time.
        XCTAssertEqual(Queue.decide(item(acted: -30, askedForPR: true), facts: facts(.openPR), now: now), .wait)
        if case .finish(.needsYou) = Queue.decide(item(acted: -600, askedForPR: true), facts: facts(.openPR), now: now) {} else {
            XCTFail("still no PR after asking: needs you")
        }
    }

    func testAPullRequestGoesToQuorumsFixLoopAndStopsAtReady() {
        XCTAssertEqual(Queue.decide(item(), facts: facts(.review, hasPR: true), now: now), .babysit)
        // quorum just started: its status isn't there yet, don't start it twice.
        XCTAssertEqual(Queue.decide(item(acted: -20, babysits: 1), facts: facts(.review, hasPR: true), now: now), .wait)
        XCTAssertEqual(Queue.decide(item(babysits: 1), facts: facts(.wait("quorum babysits"), hasPR: true), now: now), .wait)
        XCTAssertEqual(Queue.decide(item(babysits: 1), facts: facts(.land, hasPR: true), now: now), .finish(.ready))
    }

    func testQueueContinuesToQuorumWithoutHumanAcceptance() {
        XCTAssertEqual(Queue.decide(item(), facts: facts(.accept, hasPR: true), now: now),
                       .babysit)
    }

    func testFixLoopUsesDefaultRepairLimit() {
        XCTAssertEqual(Queue.decide(item(babysits: 1), facts: facts(.fix("Fix CI"), hasPR: true), now: now), .babysit)
        XCTAssertEqual(Queue.decide(item(babysits: 2), facts: facts(.fix("Fix CI"), hasPR: true), now: now), .babysit)
        XCTAssertEqual(Queue.decide(item(babysits: 3), facts: facts(.fix("Fix CI"), hasPR: true), now: now), .finish(.needsYou("Fix CI")))
    }

    func testFixLoopUsesRepairLimit() {
        var limited = item(babysits: 1)
        limited.limits = AutomationLimits(hours: 8, reviews: 1, repairs: 2)
        XCTAssertEqual(Queue.decide(limited, facts: facts(.fix("Fix CI"), hasPR: true), now: now), .babysit)

        limited.babysits = 2
        XCTAssertEqual(Queue.decide(limited, facts: facts(.fix("Fix CI"), hasPR: true), now: now), .finish(.needsYou("Fix CI")))
    }

    func testReviewAttemptsDoNotConsumeRepairAttempts() {
        var limited = item()
        limited.limits = AutomationLimits(hours: 8, reviews: 1, repairs: 1)
        limited.reviews = 1
        limited.repairs = 0

        XCTAssertEqual(Queue.decide(limited, facts: facts(.review, hasPR: true), now: now),
                       .finish(.needsYou(L("Review attempt limit reached."))))
        XCTAssertEqual(Queue.decide(limited, facts: facts(.fix("Fix CI"), hasPR: true), now: now), .babysit)
    }

    func testFailedDeliveryDoesNotAwaitATurn() {
        var waiting = item()
        waiting.awaitingAgent = true
        waiting.awaitedTurns = 4
        let failed = Queue.failedHandoff(waiting, message: "Retry the request.", now: now)
        XCTAssertEqual(failed.phase, .needsYou("Retry the request."))
        XCTAssertEqual(failed.acted, now)
        XCTAssertNil(failed.awaitingAgent)
        XCTAssertNil(failed.awaitedTurns)
    }

    func testAnswerKeepsTheOriginalTimeBudget() {
        var waiting = item(started: -3600)
        waiting.phase = .needsYou("Answer the question.")

        let resumed = Queue.resumed(waiting, awaitingAgent: true, turns: 3, now: now)

        XCTAssertEqual(resumed.started, waiting.started)
        XCTAssertEqual(resumed.phase, .running)
        XCTAssertEqual(resumed.awaitedTurns, 3)
    }

    func testNewTaskDoesNotUseAnEarlierMergeForTheSameIssue() {
        var replacement = item(started: 0)
        let old = WorkItem(root: "/repo", branch: "7-old", title: "Old task", issue: issue,
                           pr: 1, prState: "merged", created: now.addingTimeInterval(-7200),
                           touched: now.addingTimeInterval(-3600))

        XCTAssertFalse(Queue.recordsMerge(old, for: replacement))
        replacement.started = now.addingTimeInterval(-7200)
        XCTAssertTrue(Queue.recordsMerge(old, for: replacement))
    }

    func testWithoutQuorumAPullRequestIsReady() {
        XCTAssertEqual(Queue.decide(item(), facts: facts(.review, hasPR: true, quorum: false), now: now), .finish(.ready))
    }

    func testQuestionsAndErrorsAreYours() {
        XCTAssertEqual(Queue.decide(item(), facts: facts(.answer, agent: .blocked), now: now),
                       .finish(.needsYou(L("The agent asks you something."))))
        XCTAssertEqual(Queue.decide(item(), facts: facts(.wait("x"), agent: .failed), now: now),
                       .finish(.needsYou(L("The agent stopped on an error."))))
    }

    func testATurnWithoutChangesEndsOnlyAfterAWhile() {
        let waiting = NextStep.wait("Waiting for your next prompt")
        XCTAssertEqual(Queue.decide(item(), facts: facts(waiting, idle: -10), now: now), .wait)
        XCTAssertEqual(Queue.decide(item(), facts: facts(waiting, idle: -200), now: now),
                       .finish(.needsYou(L("The agent stopped without changes."))))
        // Idle while quorum or CI works on the PR: not the end.
        XCTAssertEqual(Queue.decide(item(), facts: facts(.wait("CI is running"), idle: -2000, hasPR: true), now: now), .wait)
    }

    func testMergedMeanwhileIsReadyAndNothingRunsForever() {
        XCTAssertEqual(Queue.decide(item(), facts: facts(.none, merged: true), now: now), .finish(.ready))
        if case .finish(.needsYou) = Queue.decide(item(started: -9 * 3600), facts: facts(.wait("Working"), agent: .working), now: now) {} else {
            XCTFail("eight hours is the cap")
        }
    }

    func testItemsSurviveEncoding() throws {
        var item = item(babysits: 1)
        item.phase = .needsYou("Fix CI")
        let back = try JSONDecoder().decode(Queue.Item.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
    }

    func testUnattendedPromptSaysNobodyAnswers() {
        XCTAssertTrue(Queue.unattendedNote.contains("unattended"))
        XCTAssertTrue(Queue.unattendedNote.contains("open a regular (non-draft) pull request yourself"))
    }
}

final class ImplementSkillTests: XCTestCase {
    func testFindsTheRepositorysImplementSkillOrCommand() throws {
        let repo = try TempRepo()
        XCTAssertFalse(Issues.implementSkill(in: repo.root))
        try repo.write(".claude/skills/implement/SKILL.md", "---\nname: implement\n---\n")
        XCTAssertTrue(Issues.implementSkill(in: repo.root))
        let other = try TempRepo(name: "other")
        try other.write(".claude/commands/implement.md", "Implement it.\n")
        XCTAssertTrue(Issues.implementSkill(in: other.root))
    }
}
