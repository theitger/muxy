import AppKit
import SwiftUI

/// The session list needs a persistent affordance when it overflows, even
/// when macOS otherwise uses scrollbars that disappear after scrolling.
/// Place the probe inside the scroll content so only this list is changed.
struct SessionScrollIndicator: NSViewRepresentable {
    /// Native dragging/page scrolling, with a thumb that does not fade out.
    final class Scroller: NSScroller {
        override func draw(_ dirtyRect: NSRect) {
            guard knobProportion > 0, knobProportion < 1 else { return }
            let knob = rect(for: .knob)
            guard !knob.isEmpty else { return }
            let inset = max(0, (knob.width - 6) / 2)
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: knob.insetBy(dx: inset, dy: 2), xRadius: 3, yRadius: 3).fill()
        }
    }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureAfterLayout()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureAfterLayout()
        }

        func configureAfterLayout() {
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView else { return }
                if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
                if !scroll.hasVerticalScroller { scroll.hasVerticalScroller = true }
                if !(scroll.verticalScroller is Scroller) {
                    scroll.verticalScroller = Scroller()
                    scroll.verticalScroller?.scrollerStyle = .legacy
                }
                if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configureAfterLayout() }
}
