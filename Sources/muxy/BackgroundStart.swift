import AppKit
import GhosttyTerminal

/// libghostty builds a surface only for a view inside a window, so a
/// session nobody looks at would never start its program: an agent launched
/// while another session holds the stage would wait until you click it.
/// This window is never shown; a terminal joins it just long enough for its
/// surface to exist, and the surface stays when it leaves.
@MainActor
enum BackgroundStart {
    private static let window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }()

    /// The stage's last size: the program starts with the grid it will
    /// be shown at.
    static var size = NSSize(width: 1000, height: 700)

    static func start(_ session: TerminalSession) {
        let view = session.terminalView
        guard view.window == nil, view.currentSurface == nil, let content = window.contentView else { return }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: size)
        content.addSubview(view)
        DispatchQueue.main.async {
            // Shown meanwhile: the stage owns it now.
            guard view.superview === content else { return }
            view.setSurfaceVisible(false)
            view.removeFromSuperview()
        }
    }
}
