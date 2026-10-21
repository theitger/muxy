import AppKit
import SwiftUI
import XCTest
@testable import muxy

@MainActor
final class SkeletonTests: XCTestCase {
    func testCardPlaceholderKeepsRealCardHeightIncludingTallerLabelCards() {
        for height: CGFloat in [180, 260, 340] {
            let host = NSHostingView(rootView: SkeletonTaskCard(height: height)
                .frame(width: 280))
            XCTAssertEqual(host.fittingSize.height, height, accuracy: 1)
            XCTAssertEqual(host.fittingSize.width, 280, accuracy: 1)
        }
    }

    func testSkeletonAndLoadedCardsUseIdenticalAdaptiveGridGeometry() {
        for width: CGFloat in [600, 976, 1152] {
            let loading = NSHostingView(rootView: TaskCardGrid {
                ForEach(0 ..< 6) { _ in SkeletonTaskCard() }
            }.frame(width: width))
            let loaded = NSHostingView(rootView: TaskCardGrid {
                ForEach(0 ..< 6) { _ in Text("Task").frame(maxWidth: .infinity).frame(height: 180) }
            }.frame(width: width))
            XCTAssertEqual(loading.fittingSize.height, loaded.fittingSize.height, accuracy: 1)
            XCTAssertEqual(loading.fittingSize.width, loaded.fittingSize.width, accuracy: 1)
        }
    }

    func testFileWorktreeAndReviewSkeletonsUseTheirLoadedRowHeights() {
        for (kind, height): (SkeletonList.Kind, CGFloat) in [(.files, 38), (.worktrees, 46), (.reviews, 58)] {
            let host = NSHostingView(rootView: SkeletonList(kind: kind, count: 1)
                .frame(width: 700))
            XCTAssertEqual(host.fittingSize.height, height, accuracy: 1)
        }
    }
}
