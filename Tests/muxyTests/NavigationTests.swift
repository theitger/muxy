import XCTest
@testable import muxy

@MainActor
final class NavigationTests: XCTestCase {
    func testQueueHasItsOwnDestinationAndClearsPreviouslyOpenedTask() {
        let window = WindowModel()
        window.openTask(TaskTarget(root: "/missing", branch: "feature", title: "Task"))
        window.openLibrary("queue")
        XCTAssertEqual(window.destination, .library)
        XCTAssertEqual(window.libraryPage, "queue")
        XCTAssertNil(window.taskTarget)
        XCTAssertNil(window.reviewRun)
    }

    func testFreshWindowStartsAtHomeWithoutCreatingWork() {
        let window = WindowModel()
        XCTAssertEqual(window.destination, .home)
        XCTAssertNil(window.selectedWorkspaceID)
        XCTAssertTrue(window.workspaces.isEmpty)
        XCTAssertFalse(window.showHub)
    }

    func testToolsDoNotLeakAnOldTaskOrReviewIntoAnotherPage() {
        let window = WindowModel()
        window.openTask(TaskTarget(root: "/missing", branch: "feature", title: "Saved task"))
        XCTAssertNotNil(window.taskTarget)
        XCTAssertTrue(window.showHub)

        window.openLibrary("worktrees")
        XCTAssertNil(window.taskTarget)
        XCTAssertNil(window.reviewRun)
        XCTAssertEqual(window.libraryPage, "worktrees")
        XCTAssertEqual(window.destination, .library)

        window.goHome()
        XCTAssertEqual(window.destination, .home)
        XCTAssertNil(window.taskTarget)
    }

    func testSelectingWorkRestoresItsOwnToolAfterVisitingOtherWorkAndHome() {
        let window = WindowModel()
        // No terminal is needed to exercise navigation identity.
        let first = Workspace(windowID: window.id)
        let second = Workspace(windowID: window.id)
        window.select(first)
        window.showSection(.inspect)
        window.select(second)
        XCTAssertEqual(window.workSection, .terminal)
        window.showSection(.result)

        window.goHome()
        window.select(first)
        XCTAssertEqual(window.destination, .workspace)
        XCTAssertEqual(window.workSection, .inspect)
        window.select(second)
        XCTAssertEqual(window.workSection, .result)
    }

    func testRepositoryStartDoesNotReuseThePreviouslyRequestedRepository() {
        let window = WindowModel()
        window.newTask(in: "/repo/a")
        XCTAssertEqual(window.newTaskDirectory, "/repo/a")
        XCTAssertTrue(window.showNewSession)
        window.showNewSession = false
        window.newTask()
        XCTAssertNil(window.newTaskDirectory)
    }

    func testClosingTheLibraryWithoutAnActiveWorkspaceReturnsHome() {
        let window = WindowModel()
        window.openLibrary("attention")
        window.showHub = false
        XCTAssertEqual(window.destination, .home)
        window.repairSelection(near: 0)
        XCTAssertEqual(window.destination, .home)
    }

    func testTerminalFocusDoesNotHideStartOrInspection() {
        let window = WindowModel()
        window.terminalFocus = true
        window.select(Workspace(windowID: window.id))
        XCTAssertTrue(window.isTerminalFocused)
        window.showSection(.inspect)
        XCTAssertFalse(window.isTerminalFocused)
        window.showSection(.terminal)
        XCTAssertTrue(window.isTerminalFocused)
        window.goHome()
        XCTAssertFalse(window.isTerminalFocused)
    }

    func testExplicitTerminalColorChoicesArePreserved() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: TerminalColors.storageKey)
        defer {
            if let saved { defaults.set(saved, forKey: TerminalColors.storageKey) }
            else { defaults.removeObject(forKey: TerminalColors.storageKey) }
        }
        defaults.set(TerminalColors.neutral.rawValue, forKey: TerminalColors.storageKey)
        XCTAssertEqual(TerminalColors.current, .neutral)
        defaults.set(TerminalColors.ghostty.rawValue, forKey: TerminalColors.storageKey)
        XCTAssertEqual(TerminalColors.current, .ghostty)
    }

    func testPreviewDoesNotSqueezeTheTerminalAtLaptopWindowWidths() {
        // 1280 pt window with the default sidebar: switch tools, don't split.
        XCTAssertNil(WorkbenchLayout.previewWidth(available: 1280 - 256))
        // Wider laptop windows can split while retaining at least 800 pt.
        for width: CGFloat in [1512 - 256, 1728 - 256] {
            let preview = WorkbenchLayout.previewWidth(available: width)
            XCTAssertNotNil(preview)
            XCTAssertGreaterThanOrEqual(width - (preview ?? 0) - 1, 800)
            XCTAssertGreaterThanOrEqual(preview ?? 0, WorkbenchLayout.previewMinimum)
        }
        // Large terminal fonts/zoom must be respected too.
        XCTAssertNil(WorkbenchLayout.previewWidth(available: 1256, terminalMinimum: 1000))
    }
}
