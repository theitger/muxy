import SwiftUI
import AppKit

/// Watches this dialog's actual bounds, including when its parent scrolls.
/// The outside click is consumed so it cannot activate content underneath.
struct DialogOutsideClick: NSViewRepresentable {
    var dismiss: () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.dismiss = dismiss
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak view] event in
            MainActor.assumeIsolated {
                guard let view else { return event }
                return view.handle(event)
            }
        }
        return view
    }

    func updateNSView(_ view: Probe, context: Context) { view.dismiss = dismiss }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor) }
        view.monitor = nil
    }

    final class Probe: NSView {
        var dismiss: () -> Void = {}
        var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard !bounds.contains(point) else { return event }
            dismiss()
            return nil
        }
    }
}
