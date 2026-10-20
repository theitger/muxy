import XCTest
@testable import muxy

final class TaskDependenciesTests: XCTestCase {
    func testRejectsSelfMissingAndTransitiveCycles() {
        let graph = ["A": ["B"], "B": ["C"], "C": [], "D": []]
        XCTAssertNotNil(TaskDependencies.validate(id: "C", dependencies: ["C"], graph: graph))
        XCTAssertNotNil(TaskDependencies.validate(id: "C", dependencies: ["missing"], graph: graph))
        XCTAssertNotNil(TaskDependencies.validate(id: "C", dependencies: ["A"], graph: graph))
        XCTAssertNil(TaskDependencies.validate(id: "D", dependencies: ["A", "C"], graph: graph))
    }

    func testOnlyConfirmedMergesReleaseDependencies() {
        XCTAssertEqual(TaskDependencies.waiting(["A", "B"], merged: []), ["A", "B"])
        XCTAssertEqual(TaskDependencies.waiting(["A", "B"], merged: ["A"]), ["B"])
        XCTAssertEqual(TaskDependencies.waiting(["A", "B"], merged: ["A", "B"]), [])
        // A missing predecessor stays blocking rather than disappearing from the graph.
        XCTAssertEqual(TaskDependencies.waiting(["removed"], merged: ["other"]), ["removed"])
    }
}

@MainActor
final class TaskLedgerTests: XCTestCase {
    private func temp() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testNotesDraftFeedbackAndExactHeadSurviveRestart() throws {
        let file = try temp().appendingPathComponent("tasks.json")
        let ledger = TaskLedger(file: file)
        let head = String(repeating: "a", count: 40)
        XCTAssertTrue(ledger.update("o/r#7") {
            $0.goal = "Clear the expired cookie"
            $0.draft = "Also handle an expired refresh token"
            $0.criteria = [TaskCriterion(text: "An expired session redirects once", checkedHead: head)]
            $0.feedback = [TaskFeedback(text: "Keep the query string", head: head)]
            $0.lastInspectedHead = head
        })
        let restored = TaskLedger(file: file)
        XCTAssertEqual(restored.records, ledger.records)
        let record = try XCTUnwrap(restored.records["o/r#7"])
        XCTAssertTrue(record.satisfied(at: head))
        XCTAssertFalse(record.satisfied(at: String(repeating: "b", count: 40)))
        XCTAssertFalse(record.satisfied(at: nil))
        XCTAssertTrue(restored.update("o/r#7") { $0.criteria.append(TaskCriterion(text: "Keep the query string")) })
        XCTAssertFalse(restored.records["o/r#7"]!.satisfied(at: head))
    }

    func testIssueCheckboxesNeedFreshHumanConfirmation() {
        let criteria = TaskRecord.criteria(from: "- [x] Already checked on GitHub\n- [ ] Still to do\n- [X] Imported\n- [ ] \nordinary text")
        XCTAssertEqual(criteria.map(\.text), ["Already checked on GitHub", "Still to do", "Imported"])
        XCTAssertTrue(criteria.allSatisfy { $0.checkedHead == nil })
    }

    func testStagedFeedbackSurvivesARetry() throws {
        let file = try temp().appendingPathComponent("tasks.json")
        let ledger = TaskLedger(file: file)
        let request = TaskFeedback(text: "Keep the query string", head: "abc", screenshot: "/tmp/preview.png")
        var first = request
        XCTAssertTrue(ledger.update("o/r#7") { first = $0.stageFeedback(request) })

        let restored = TaskLedger(file: file)
        var retry = request
        XCTAssertTrue(restored.update("o/r#7") { retry = $0.stageFeedback(request) })
        XCTAssertEqual(retry.id, first.id)
        XCTAssertTrue(restored.records["o/r#7"]?.feedback.isEmpty == true)

        XCTAssertTrue(restored.update("o/r#7") { $0.commitFeedback(retry) })
        XCTAssertEqual(restored.records["o/r#7"]?.feedback, [first])
        XCTAssertNil(restored.records["o/r#7"]?.pendingFeedback)
    }

    func testCorruptAndUnwritableFilesDoNotPretendToSave() throws {
        let folder = try temp()
        let corrupt = folder.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: corrupt)
        let broken = TaskLedger(file: corrupt)
        XCTAssertNotNil(broken.problem)
        XCTAssertFalse(broken.update("task") { $0.goal = "overwrite" })
        XCTAssertEqual(try String(contentsOf: corrupt), "broken")
        let parentFile = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: parentFile)
        let unavailable = TaskLedger(file: parentFile.appendingPathComponent("tasks.json"))
        XCTAssertFalse(unavailable.update("task") { $0.goal = "lost" })
        XCTAssertTrue(unavailable.records.isEmpty)
        XCTAssertNotNil(unavailable.problem)
    }

    func testWriteFailureCanBeRetriedAfterTheParentIsRestored() throws {
        let folder = try temp()
        let parent = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: parent)
        let ledger = TaskLedger(file: parent.appendingPathComponent("tasks.json"))

        XCTAssertFalse(ledger.update("task") { $0.goal = "saved" })
        XCTAssertNotNil(ledger.problem)
        XCTAssertFalse(ledger.persistenceBlocked)

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertTrue(ledger.update("task") { $0.goal = "saved" })
        XCTAssertNil(ledger.problem)
        XCTAssertEqual(TaskLedger(file: parent.appendingPathComponent("tasks.json")).records["task"]?.goal, "saved")
    }

    func testOnlyRecordedUserRequirementsAreAddedToThePrompt() throws {
        let ledger = TaskLedger(file: try temp().appendingPathComponent("tasks.json"))
        let issue = Issue(repo: "o/r", number: 7, title: "Fix login", url: "", state: "OPEN")
        XCTAssertEqual(ledger.instructions(for: issue), "")
        XCTAssertTrue(ledger.update("o/r#7") { $0.goal = "Keep the existing redirect URL"; $0.criteria = [TaskCriterion(text: "Preserve query parameters")] })
        XCTAssertTrue(ledger.instructions(for: issue).contains("Keep the existing redirect URL"))
        XCTAssertTrue(ledger.instructions(for: issue).contains("- Preserve query parameters"))
    }
}

@MainActor
final class LandingRecoveryTests: XCTestCase {
    private func temp() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func receipt(_ step: Landing.Step) -> LandingReceipt {
        LandingReceipt(root: "/repo", branch: "feat/7", pr: 7, goal: .land, step: step,
                       since: Date(timeIntervalSince1970: 100), started: Date(timeIntervalSince1970: 10), asks: 2,
                       quorumSince: Date(timeIntervalSince1970: 50), provenHead: String(repeating: "a", count: 40))
    }

    func testInFlightExternalOperationsAreObservedNotReplayed() {
        XCTAssertEqual(receipt(.reviewing).recovery(accepted: false, agentWorking: false), .observe)
        XCTAssertEqual(receipt(.merging("Waiting for GitHub")).recovery(accepted: false, agentWorking: false), .observe)
        var unconfirmed = receipt(.reviewing)
        unconfirmed.quorumSince = nil
        XCTAssertEqual(unconfirmed.recovery(accepted: true, agentWorking: false), .inspect)
        unconfirmed = receipt(.merging("Sending"))
        unconfirmed.provenHead = nil
        XCTAssertEqual(unconfirmed.recovery(accepted: true, agentWorking: false), .inspect)
    }

    func testNoRepeatedAgentRequestAndNoResumeAgainstAnUnacceptedHead() {
        XCTAssertEqual(receipt(.waitingForAgent("Fix checks")).recovery(accepted: true, agentWorking: true), .observe)
        XCTAssertEqual(receipt(.waitingForAgent("Fix checks")).recovery(accepted: true, agentWorking: false), .inspect)
        for step in [Landing.Step.proving, .pushing, .preparing("Inspecting")] {
            XCTAssertEqual(receipt(step).recovery(accepted: true, agentWorking: false), .check)
            XCTAssertEqual(receipt(step).recovery(accepted: false, agentWorking: false), .inspect)
        }
    }

    func testTheJournalPreservesCountersHeadsAndOriginalClocks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("landing.json")
        let journal = LandingJournal(file: file)
        var active = receipt(.reviewing)
        active.reviewAttempts = 1
        active.requiresInspection = false
        XCTAssertTrue(journal.put(active))
        XCTAssertEqual(LandingJournal(file: file).receipts[active.id], active)
        var paused = active
        paused.requiresInspection = true
        paused.step = .failed("Launch unconfirmed")
        XCTAssertTrue(journal.put(paused))
        let again = LandingJournal(file: file)
        XCTAssertEqual(again.receipts[active.id], paused)
        XCTAssertFalse(again.receipts[active.id]!.step.isActive)
    }

    func testACorruptJournalIsPreservedAndBlocksNewIntents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        let journal = LandingJournal(file: file)
        XCTAssertNotNil(journal.problem)
        XCTAssertFalse(journal.put(receipt(.pushing)))
        XCTAssertEqual(try String(contentsOf: file), "not json")
    }

    func testJournalWriteFailureCanBeRetriedAfterTheParentIsRestored() throws {
        let folder = try temp()
        let parent = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: parent)
        let journal = LandingJournal(file: parent.appendingPathComponent("landing.json"))

        XCTAssertFalse(journal.put(receipt(.pushing)))
        XCTAssertNotNil(journal.problem)
        XCTAssertFalse(journal.persistenceBlocked)

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertTrue(journal.put(receipt(.pushing)))
        XCTAssertNil(journal.problem)
        XCTAssertEqual(LandingJournal(file: parent.appendingPathComponent("landing.json")).receipts.count, 1)
    }
}

final class AutomationBudgetTests: XCTestCase {
    func testBudgetsCannotBecomeUnboundedThroughBadSavedValues() {
        let low = AutomationLimits(hours: -1, reviews: -2, repairs: -3)
        XCTAssertEqual(low.seconds, 3600)
        XCTAssertEqual(low.reviewAttempts, 0)
        XCTAssertEqual(low.repairAttempts, 0)
        let high = AutomationLimits(hours: Int.max, reviews: Int.max, repairs: Int.max)
        XCTAssertEqual(high.seconds, 48 * 3600)
        XCTAssertEqual(high.reviewAttempts, 10)
        XCTAssertEqual(high.repairAttempts, 10)
    }

    func testCustomTimeAndReviewLimitsApplyToEveryQueueReviewPath() {
        let now = Date()
        var item = Queue.Item(issue: Issue(repo: "o/r", number: 1, title: "Fix", url: "", state: "OPEN"), agent: .codex)
        item.limits = AutomationLimits(hours: 1, reviews: 1, repairs: 1)
        item.started = now.addingTimeInterval(-7200)
        let working = Queue.Facts(step: .wait("Working"), agent: .working, hasPR: false, quorumInstalled: true, merged: false)
        if case .finish(.needsYou) = Queue.decide(item, facts: working, now: now) {} else { XCTFail("Custom time limit ignored") }
        item.started = now
        item.babysits = 1
        for step in [NextStep.review, .fix("CI failed")] {
            let facts = Queue.Facts(step: step, agent: .idle, hasPR: true, quorumInstalled: true, merged: false)
            if case .finish(.needsYou) = Queue.decide(item, facts: facts, now: now) {} else { XCTFail("Review limit ignored") }
        }
    }

    func testPausedQueueStillMonitorsActiveWorkAfterRestart() {
        var item = Queue.Item(issue: Issue(repo: "o/r", number: 1, title: "Fix", url: "", state: "OPEN"), agent: .claude)
        item.phase = .running
        XCTAssertTrue(Queue.shouldMonitor(running: false, items: [item]))
        item.phase = .planReady
        XCTAssertTrue(Queue.shouldMonitor(running: false, items: [item]))
        item.phase = .queued
        XCTAssertFalse(Queue.shouldMonitor(running: false, items: [item]))
    }
}

@MainActor
final class QueuePersistenceTests: XCTestCase {
    private struct SavedQueue: Codable {
        var items: [Queue.Item]
        var running: Bool
        var merged: Set<String>?
    }

    func testDependenciesAndLimitsSurviveAndRemovalWaitsForDependentsToMerge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("queue.json")
        let queue = Queue(file: file, restoreLegacy: false)
        let a = Issue(repo: "o/r", number: 1, title: "Schema", url: "", state: "OPEN")
        let b = Issue(repo: "o/r", number: 2, title: "UI", url: "", state: "OPEN")
        queue.add(a, agent: .claude)
        queue.add(b, agent: .codex)
        let limits = AutomationLimits(hours: 2, reviews: 1, repairs: 2)
        XCTAssertNil(queue.configure(queue.items[1], dependencies: [queue.items[0].id], limits: limits))
        let again = Queue(file: file, restoreLegacy: false)
        XCTAssertEqual(again.items, queue.items)
        XCTAssertEqual(again.waiting(for: again.items[1]), ["o/r#1"])
        again.remove(again.items[0])
        XCTAssertEqual(again.items.count, 2)
        XCTAssertNotNil(again.configure(again.items[0], dependencies: ["o/r#2"], limits: limits))

        var saved = try JSONDecoder().decode(SavedQueue.self, from: Data(contentsOf: file))
        saved.merged = [again.items[0].id]
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        let mergedPrerequisite = Queue(file: file, restoreLegacy: false)
        mergedPrerequisite.remove(mergedPrerequisite.items[0])
        XCTAssertEqual(mergedPrerequisite.items.count, 2)

        saved.merged = [again.items[1].id]
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        let mergedDependent = Queue(file: file, restoreLegacy: false)
        mergedDependent.remove(mergedDependent.items[0])
        XCTAssertEqual(mergedDependent.items.count, 1)
    }

    func testQueueCanSaveAgainAfterItsFileBecomesWritable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blockedParent = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedParent)
        let queue = Queue(file: blockedParent.appendingPathComponent("queue.json"), restoreLegacy: false)
        let first = Issue(repo: "o/r", number: 1, title: "First", url: "", state: "OPEN")
        let second = Issue(repo: "o/r", number: 2, title: "Second", url: "", state: "OPEN")

        queue.add(first, agent: .claude)
        XCTAssertNotNil(queue.problem)
        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: true)

        queue.add(second, agent: .codex)
        XCTAssertNil(queue.problem)
        XCTAssertEqual(Queue(file: blockedParent.appendingPathComponent("queue.json"), restoreLegacy: false).items.map(\.issue.number), [1, 2])
    }

    func testRequeueingClearsAnOlderMergeReceipt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("queue.json")
        let issue = Issue(repo: "o/r", number: 1, title: "Again", url: "", state: "OPEN")
        let previous = Queue.Item(issue: issue, agent: .claude)
        let saved = SavedQueue(items: [previous], running: false, merged: [previous.id])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: file, options: .atomic)

        let queue = Queue(file: file, restoreLegacy: false)
        queue.remove(queue.items[0])
        queue.add(issue, agent: .codex)

        XCTAssertFalse(queue.merged.contains(previous.id))
        XCTAssertEqual(queue.items.count, 1)
    }

    func testCorruptQueueIsNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("queue.json")
        try Data("broken".utf8).write(to: file)
        let queue = Queue(file: file, restoreLegacy: false)

        queue.add(Issue(repo: "o/r", number: 1, title: "First", url: "", state: "OPEN"), agent: .claude)

        XCTAssertNotNil(queue.problem)
        XCTAssertEqual(try String(contentsOf: file), "broken")
    }
}

final class MergeOrderTests: XCTestCase {
    func testSameRepositoryWaitsAndOtherRepositoriesProceed() {
        let first = MergeOrder.Entry(id: "A", root: "/repo", started: Date(timeIntervalSince1970: 1), waiting: false)
        let second = MergeOrder.Entry(id: "B", root: "/repo", started: Date(timeIntervalSince1970: 2), waiting: true)
        let other = MergeOrder.Entry(id: "C", root: "/other", started: second.started, waiting: true)
        XCTAssertFalse(MergeOrder.mayStart(second, among: [first, second]))
        XCTAssertTrue(MergeOrder.mayStart(other, among: [first, second, other]))
        XCTAssertTrue(MergeOrder.mayStart(second, among: [second]))
    }

    func testOldestWaitingRequestWinsAndTiesAreDeterministic() {
        let first = MergeOrder.Entry(id: "A", root: "/repo", started: Date(timeIntervalSince1970: 1), waiting: true)
        let second = MergeOrder.Entry(id: "B", root: "/repo", started: first.started, waiting: true)
        XCTAssertTrue(MergeOrder.mayStart(first, among: [first, second]))
        XCTAssertFalse(MergeOrder.mayStart(second, among: [first, second]))
    }
}

final class TaskInspectionTests: XCTestCase {
    func testOnlyChangesSinceTheInspectedCommitAreShown() throws {
        let repo = try TempRepo()
        let inspected = try repo.head()
        try repo.write("new.txt", "after inspection\n")
        try repo.commit("Next implementation")
        let result = ReviewModel.diff(scope: .sinceInspection(inspected), checkout: repo.root, root: repo.root, checkpoints: [])
        XCTAssertNil(result.1)
        XCTAssertEqual(result.0.map(\.path), ["new.txt"])
        let missing = ReviewModel.diff(scope: .sinceInspection(String(repeating: "a", count: 40)), checkout: repo.root, root: repo.root, checkpoints: [])
        XCTAssertTrue(missing.0.isEmpty)
        XCTAssertNotNil(missing.1)
    }
}

final class TaskBaseTests: XCTestCase {
    func testAFreshRemoteBaseIsFetchedWithoutChangingTheUsersCheckout() throws {
        let repo = try TempRepo()
        try repo.addOrigin()
        let before = try repo.head()
        // A remote update arrives after the local tracking ref was last read.
        let contributor = try repo.addWorktree("contributor", branch: "contributor")
        try repo.write("schema.txt", "new schema\n", in: contributor)
        try repo.commit("Prerequisite merged", in: contributor)
        let merged = try repo.head(in: contributor)
        try repo.git("push", "--quiet", "origin", "contributor:main", in: contributor)
        try repo.git("update-ref", "refs/remotes/origin/main", before)
        try repo.write("local.txt", "Keep my unfinished work\n")
        XCTAssertNil(TaskBase.refresh(in: repo.root))
        XCTAssertEqual(try repo.git("rev-parse", "origin/main"), merged)
        XCTAssertEqual(try repo.head(), before)
        XCTAssertEqual(repo.read("local.txt"), "Keep my unfinished work\n")
    }

    func testUnavailableRemoteDoesNotPretendTheBaseIsFresh() throws {
        let repo = try TempRepo()
        XCTAssertNotNil(TaskBase.refresh(in: repo.root))
        try repo.addOrigin()
        try repo.git("remote", "set-url", "origin", repo.base + "/does-not-exist.git")
        XCTAssertNotNil(TaskBase.refresh(in: repo.root))
    }
}

final class TaskFollowupTests: XCTestCase {
    func testAUserReplyWaitsForTheAgentWithoutResendingIt() {
        let now = Date()
        var item = Queue.Item(issue: Issue(repo: "o/r", number: 7, title: "Fix", url: "", state: "OPEN"), agent: .codex)
        item.awaitingAgent = true
        item.awaitedTurns = 3
        item.acted = now
        XCTAssertEqual(Queue.followup(item, agent: .idle, turns: 3, now: now), .waiting)
        XCTAssertEqual(Queue.followup(item, agent: .blocked, turns: 3, now: now), .waiting)
        XCTAssertEqual(Queue.followup(item, agent: .working, turns: 3, now: now), .started)
        // A fast turn may start and finish between two queue ticks.
        XCTAssertEqual(Queue.followup(item, agent: .idle, turns: 4, now: now), .started)
        XCTAssertEqual(Queue.followup(item, agent: .idle, turns: 3, now: now.addingTimeInterval(100)), .unconfirmed)
    }
}
