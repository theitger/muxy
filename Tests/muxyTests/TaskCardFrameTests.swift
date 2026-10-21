import AppKit
import SwiftUI
import XCTest
@testable import muxy

@MainActor
final class TaskCardFrameTests: XCTestCase {
    func testActionsKeepTheSameBottomEdgeForDifferentTitlesLabelsAndFooterRows() {
        let bounds = CGRect(x: 14, y: 14, width: 280, height: 280)
        for header: CGFloat in [35, 75, 120] {
            for footer: CGFloat in [22, 57, 80] {
                let frames = TaskCardBodyLayout.frames(in: bounds, header: header, actions: footer)
                XCTAssertEqual(frames[2].maxY, bounds.maxY)
                XCTAssertEqual(frames[0].minY, bounds.minY)
                XCTAssertGreaterThanOrEqual(frames[1].minY, frames[0].maxY)
                XCTAssertLessThanOrEqual(frames[1].maxY, frames[2].minY)
            }
        }
    }

    func testNoDescriptionSpaceRemainsWhenMetadataAndActionsFillTheCard() {
        let frames = TaskCardBodyLayout.frames(in: CGRect(x: 0, y: 0, width: 280, height: 160),
                                               header: 120, actions: 26)
        XCTAssertEqual(frames[1].height, 0)
        XCTAssertEqual(frames[2].maxY, 160)
    }

    func testLongLabelListsGrowTheCardInsteadOfClippingMetadataOrActions() {
        let host = NSHostingView(rootView: TaskCardFrame(description: "Preview text") {
            VStack(alignment: .leading) {
                Text("A task title")
                TaskLabels(labels: (1 ... 20).map { "Label number \($0)" })
            }
        } actions: {
            Text("Start Claude").frame(height: 22)
        }.frame(width: 280))
        XCTAssertGreaterThan(host.fittingSize.height, 180)
    }
    func testGridProposalsKeepCardsAtOneHeightDespiteDifferentIntrinsicContent() {
        for width: CGFloat in [280, 600, 976, 1152] {
            var measured: [Int: CGRect] = [:]
            let grid = TaskCardGrid {
                ForEach(0 ..< 3) { index in
                    TaskCardFrame(description: String(repeating: "Long description with spaces. ", count: 50)) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(index == 1 ? String(repeating: "A long task title ", count: 8) : "Short title")
                                .font(UI.control).fixedSize(horizontal: false, vertical: true)
                            TaskLabels(labels: (0 ..< (index == 2 ? 20 : 2)).map { "Label number \($0)" })
                        }
                    } actions: {
                        FlowRow {
                            SmallButton(title: "Review and fix with quorum", prominent: true) {}
                            SmallButton(title: "Terminal") {}
                            SmallButton(title: "Changes") {}
                        }
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { measured[index] = geometry.frame(in: .named("grid")) }
                            .onChange(of: geometry.frame(in: .named("grid"))) { _, frame in measured[index] = frame }
                    })
                }
            }.coordinateSpace(name: "grid").frame(width: width)
            let host = NSHostingView(rootView: grid)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 2000),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertEqual(measured.count, 3)
            let heights = measured.values.map(\.height)
            XCTAssertEqual(heights.min() ?? 0, heights.max() ?? 1, accuracy: 1, "width \(width)")
            let ordered = measured.sorted { $0.key < $1.key }.map(\.value)
            for pair in zip(ordered, ordered.dropFirst()) {
                XCTAssertFalse(pair.0.intersects(pair.1), "Cards overlap at width \(width)")
            }
            window.contentView = nil
        }
    }

    func testDescriptionDoesNotAddReservedRowsToTheCardHeight() {
        for headerHeight: CGFloat in [50, 100] {
            for description: String? in [nil, String(repeating: "A long PR description. ", count: 60)] {
                let host = NSHostingView(rootView: TaskCardFrame(description: description) {
                    Color.clear.frame(height: headerHeight)
                } actions: {
                    TaskCardFooter(title: "Run quorum", url: "https://example.com") {} more: { Button("Task") {} }
                }.frame(width: 280))
                XCTAssertEqual(host.fittingSize.height, 180, accuracy: 1)
            }
        }
    }

    func testFooterKeepsOneHeightAcrossTitlesWidthsAndMenuSizes() {
        for width: CGFloat in [220, 280, 380] {
            for title in ["Start Claude", "Quorum starten", String(repeating: "Long action ", count: 8)] {
                let host = NSHostingView(rootView: TaskCardFooter(title: title, url: "https://example.com") {} more: {
                    ForEach(0 ..< 8) { index in Button("Action \(index)") {} }
                }.frame(width: width))
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                XCTAssertEqual(host.fittingSize.height, 26, accuracy: 1)
            }
        }
    }

    func testRenderFooterAlignmentExamples() throws {
        let path = ProcessInfo.processInfo.environment["MUXY_RENDER_DIR"]
        try XCTSkipUnless(path != nil)
        let folder = URL(fileURLWithPath: path ?? "")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cards = HStack(alignment: .top, spacing: 12) {
            ForEach(0 ..< 3) { index in
                TaskCardFrame(description: "The GitHub description fills the space between metadata and actions. Longer text is truncated before it can displace the buttons.") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("MUXY · #\(42 + index)").font(UI.metadata).foregroundStyle(Theme.textMuted)
                        Text(index == 1 ? "Keep actions aligned even when task titles wrap onto several lines" : "Task card with a short title")
                            .font(UI.control).fixedSize(horizontal: false, vertical: true)
                        TaskLabels(labels: index == 2 ? ["bug", "ready-for-agent", "priority:high", "macbook", "accessibility", "frontend"] : ["bug", "ready-for-agent"])
                    }
                } actions: {
                    TaskCardFooter(title: index == 1 ? "Quorum starten" : "Start Claude", url: "https://example.com") {} more: {
                        Button("Task") {}
                        Button("Terminal") {}
                    }
                }
                .frame(width: 300)
            }
        }.environment(\.taskCardHeight, 260).padding(20).background(Theme.bg)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            var image: CGImage?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: cards.environment(\.colorScheme, mode == "dark" ? .dark : .light))
                renderer.scale = 2
                image = renderer.cgImage
            }
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(image))
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("task-card-footers-\(mode).png"))
        }
    }

}
