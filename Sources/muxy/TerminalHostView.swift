import SwiftUI
import GhosttyTerminal

/// Hosts exactly one terminal view — the visible session's. Switching tabs
/// reparents the corresponding NSView; nothing is ever re-created. Detached
/// surfaces are marked invisible so libghostty stops rendering them.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(session.terminalView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard session.terminalView.superview != container else { return }
        for old in container.subviews {
            (old as? TerminalView)?.setSurfaceVisible(false)
            old.removeFromSuperview()
        }
        attach(session.terminalView, to: container)
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
        session.needsAttention = false
        DispatchQueue.main.async {
            terminal.fitToSize()
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}
