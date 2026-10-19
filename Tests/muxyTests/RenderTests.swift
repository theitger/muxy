import SwiftUI
import XCTest
@testable import muxy

/// Renders the result and issue views offscreen, light and dark, for a
/// look without launching muxy: MUXY_RENDER_DIR=/some/dir swift test --filter Render
@MainActor
final class RenderTests: XCTestCase {
    func testRenderResultAndIssueViews() throws {
        let path = ProcessInfo.processInfo.environment["MUXY_RENDER_DIR"]
        try XCTSkipUnless(path != nil)
        let folder = URL(fileURLWithPath: path ?? "")
        let full = SessionResult(
            summary: "Fixed the login redirect after a session expired and added a regression test. The old cookie is cleared before the new one is set.",
            tests: TestRun(command: "cd web && npm test", outcome: .failed),
            changes: DiffCount(files: 4, insertions: 38, deletions: 6),
            pr: PullRequestResult(number: 128, state: .open, url: "https://github.com/o/r/pull/128", checks: .failed, failing: ["lint", "e2e (chrome)"]),
            updated: Date()
        )
        let issue = Issue(repo: "o/r", number: 42, title: "Login redirect loops after the session expired", url: "", state: "OPEN")
        let face = WingFace(
            title: issue.heading, agent: .idle, attention: true, isGit: true, pr: 128, prStatus: .failed,
            activity: "Done", lines: ["$ npm test", "  12 passing", "  1 failing"], agents: [.idle],
            result: ResultFace(summary: full.summary, tests: .failed, checks: .failed)
        )
        let views: [(String, AnyView)] = [
            ("panel", AnyView(ResultPanel(result: full, building: false, hasAgent: true))),
            ("panel-empty", AnyView(ResultPanel(result: nil, building: false, hasAgent: true))),
            ("card", AnyView(WingCardFace(face: face, detailed: true, onStage: true).frame(width: 240))),
            ("row", AnyView(WingCardFace(face: face, detailed: false).frame(width: 240))),
            ("issue", AnyView(VStack(alignment: .leading) {
                IssueRow(issue: issue)
                IssueRow(issue: Issue(repo: "o/r", number: 7, title: "Closed one", url: "", state: "CLOSED"), prominent: false)
            }.frame(width: 480))),
        ]
        for (name, view) in views {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                var image: CGImage?
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(content: view.padding(20).background(Theme.bg)
                        .environment(\.colorScheme, mode == "dark" ? .dark : .light))
                    renderer.scale = 2
                    image = renderer.cgImage
                }
                let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(image))
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("\(name)-\(mode).png"))
            }
        }
    }
}
