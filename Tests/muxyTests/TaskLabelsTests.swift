import XCTest
import AppKit
import SwiftUI
@testable import muxy

final class TaskLabelsTests: XCTestCase {
    func testAllLabelsSurviveLoadingAndRenderingIncludingThoseAfterTheThird() {
        let labels = ["bug", "ready-for-agent", "priority:high", "frontend", "accessibility", "macbook", "needs-review"]
        let loaded = HubModel.labels(in: ["labels": labels.map { ["name": $0] }])
        XCTAssertEqual(loaded, labels)
        XCTAssertEqual(TaskLabels.unique(loaded), labels)
    }

    func testMergingIssueAndPullLabelsKeepsEveryDistinctNameInOrder() {
        XCTAssertEqual(TaskLabels.unique(["bug", "ui", "bug", "", "needs-review", "ui", "priority:high"]),
                       ["bug", "ui", "needs-review", "priority:high"])
    }

    func testMissingAndMalformedExternalLabelsDoNotCrash() {
        XCTAssertEqual(HubModel.labels(in: [:]), [])
        XCTAssertEqual(HubModel.labels(in: ["labels": NSNull()]), [])
        XCTAssertEqual(HubModel.labels(in: ["labels": [["name": "ui"], ["color": "ffffff"], ["name": 42]]]), ["ui"])
    }
}

@MainActor
final class TaskLabelLayoutTests: XCTestCase {
    func testAllLabelsWrapWithinCardWidthAndGrowInsteadOfClipping() {
        _ = NSApplication.shared
        let names = ["ready-for-agent", "priority:high", "accessibility", "frontend", "macbook", "needs-review",
                     "a-long-label-that-must-wrap-within-the-card-without-being-truncated"]
        for width: CGFloat in [250, 340] {
            let short = NSHostingView(rootView: TaskLabels(labels: Array(names.prefix(3))).frame(width: width))
            let full = NSHostingView(rootView: TaskLabels(labels: names).frame(width: width))
            XCTAssertGreaterThan(full.fittingSize.height, short.fittingSize.height)
            XCTAssertEqual(full.fittingSize.width, width, accuracy: 1)
        }
    }
}
