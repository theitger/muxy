import XCTest
import GhosttyKit
@testable import muxy

@MainActor
final class TerminalColorsTests: XCTestCase {
    func testNeutralColorsOverrideInheritedWarmBackgroundAndOpacity() throws {
        ghostty_init(0, nil)
        for (rendered, expected) in [
            (TerminalColors.neutral.theme.light.rendered, (255, 255, 255)),
            (TerminalColors.neutral.theme.dark.rendered, (9, 9, 11))
        ] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            // Simulates the warm background and transparency in a user's config.
            try ("background = #f4f4f0\nbackground-opacity = 0.95\n" + rendered).write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let config = try XCTUnwrap(ghostty_config_new())
            defer { ghostty_config_free(config) }
            file.path.withCString { ghostty_config_load_file(config, $0) }
            ghostty_config_finalize(config)
            XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)
            var color = ghostty_config_color_s()
            XCTAssertTrue(ghostty_config_get(config, &color, "background", 10))
            XCTAssertEqual(Int(color.r), expected.0)
            XCTAssertEqual(Int(color.g), expected.1)
            XCTAssertEqual(Int(color.b), expected.2)
            var opacity: Double = 0
            XCTAssertTrue(ghostty_config_get(config, &opacity, "background-opacity", 18))
            XCTAssertEqual(opacity, 1)
        }
    }
}
