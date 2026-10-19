import XCTest
@testable import muxy

/// MUXY_TIME_INVENTORY=1 swift test --filter InventoryTiming: how long a
/// scan of your real repositories takes.
final class InventoryTimingTests: XCTestCase {
    func testTimeRealScan() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUXY_TIME_INVENTORY"] != nil)
        var began = Date()
        let roots = InventoryModel.roots(open: [])
        print("roots \(roots.count) in \(Date().timeIntervalSince(began))s")
        began = Date()
        let found = Inventory.scan(roots: roots)
        print("scan \(found.count) worktrees in \(Date().timeIntervalSince(began))s")
    }
}
