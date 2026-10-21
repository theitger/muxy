import AppKit
import XCTest
@testable import muxy

@MainActor
final class DialogOutsideClickTests: XCTestCase {
    func testInsideClickContinuesAndOutsideClickDismissesWithoutClickingThrough() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let probe = DialogOutsideClick.Probe(frame: NSRect(x: 100, y: 100, width: 600, height: 400))
        window.contentView?.addSubview(probe)
        var dismissals = 0
        probe.dismiss = { dismissals += 1 }
        let inside = try event(in: window, at: NSPoint(x: 300, y: 300))
        XCTAssertNotNil(probe.handle(inside))
        XCTAssertEqual(dismissals, 0)

        let outside = try event(in: window, at: NSPoint(x: 40, y: 300))
        XCTAssertNil(probe.handle(outside))
        XCTAssertEqual(dismissals, 1)
        XCTAssertNil(probe.hitTest(NSPoint(x: 10, y: 10)), "The probe must not intercept dialog fields")
    }

    func testClickInAnotherWindowDoesNotDismissDialog() throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let probe = DialogOutsideClick.Probe(frame: NSRect(x: 100, y: 100, width: 600, height: 400))
        first.contentView?.addSubview(probe)
        var dismissed = false
        probe.dismiss = { dismissed = true }
        XCTAssertNotNil(probe.handle(try event(in: other, at: NSPoint(x: 40, y: 300))))
        XCTAssertFalse(dismissed)
    }

    private func event(in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
