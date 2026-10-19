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
