import XCTest
@testable import muxy

final class L10nTests: XCTestCase {
    /// A key twice in the table traps the moment German is first shown;
    /// several branches add strings to it.
    func testGermanTableBuilds() {
        XCTAssertFalse(German.table.isEmpty)
    }

    func testNoEmDashesInGermanStrings() {
        for (english, german) in German.table {
            XCTAssertFalse(german.contains("—"), "em dash in the German for \(english)")
        }
    }
}

final class L10nTableTests: XCTestCase {
    /// A key twice in the German table traps when the table is first read:
    /// the source is checked, since the literal can't even be built.
    func testNoKeyTwice() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/muxy/L10n.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)":"#, options: .anchorsMatchLines)
        var seen = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let key = String(text[Range(match.range(at: 1), in: text)!])
            XCTAssertTrue(seen.insert(key).inserted, "twice in German.table: \(key)")
        }
    }
}
