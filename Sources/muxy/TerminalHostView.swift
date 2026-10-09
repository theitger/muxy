import SwiftUI
import GhosttyTerminal

/// Hosts exactly one terminal view — the visible session's. Switching tabs
/// reparents the corresponding NSView; nothing is ever re-created. Detached
/// surfaces are marked invisible so libghostty stops rendering them.
///
/// The newest host owns the terminal: when a session moves to another
/// window, the old window's host may still get a last update — it must not
/// pull the terminal back (it would be torn down with the old host).
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Rounds the bottom corners when the terminal stands on the stage card
    /// (SwiftUI clipping doesn't reach AppKit views — the layer does it).
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        session.host = container
        round(container)
        attach(session.terminalView, to: container)
        // A session taking the stage fades in over the terminal background
        // rather than cutting hard from the last one.
        container.alphaValue = 0
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
                container.animator().alphaValue = 1
            }
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        round(container)
        guard session.host === container,
              session.terminalView.superview != container else { return }
        for old in container.subviews {
            (old as? TerminalView)?.setSurfaceVisible(false)
            old.removeFromSuperview()
        }
        attach(session.terminalView, to: container)
    }

    private func round(_ container: NSView) {
        container.wantsLayer = true
        guard let layer = container.layer, layer.cornerRadius != cornerRadius else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = cornerRadius > 0
    }

    private func attach(_ terminal: TerminalView, to container: NSView) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        terminal.setSurfaceVisible(true)
        session.markSeen()
        DispatchQueue.main.async {
            terminal.fitToSize()
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}
