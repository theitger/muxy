import SwiftUI
import AppKit

/// Makes the hosting window non-opaque and applies real window-server
/// background blur — the same mechanism Ghostty uses — so the terminal's
/// `background-opacity` from the user's config shows through 1:1.
struct WindowConfigurator: NSViewRepresentable {
    let model: WindowModel

    final class ConfigView: NSView {
        weak var model: WindowModel?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let model else { return }
            model.nsWindow = window
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            // The window's buttons sit centered in muxy's top bar, in line
            // with its icons. (A toolbar would do it too, but it swallows
            // every click in the title bar.) AppKit lays them out again on
            // resizes and full screen, so they are placed again after each.
            Self.alignButtons(in: window)
            if buttonObservers.isEmpty {
                for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                    buttonObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                        guard let window else { return }
                        MainActor.assumeIsolated { Self.alignButtons(in: window) }
                    })
                }
            }
            window.isRestorable = false
            window.tabbingMode = .disallowed
            // Closing goes through muxy, which confirms running work and
            // ends the window's sessions with it.
            if let close = window.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closeWindow)
            }
            if let frame = model.pendingFrame {
                model.pendingFrame = nil
                // SwiftUI positions new windows after this call — place it
                // now and once more on the next turn. (Never hide the window
                // meanwhile: a terminal attached to an invisible window
                // stops drawing.)
                window.setFrame(frame, display: false)
                DispatchQueue.main.async {
                    window.setFrame(frame, display: true)
                }
            }
            WindowBlur.apply(to: window)
            // A window opened by dragging a session out isn't known to the
            // window server yet at this point, and the blur call is lost —
            // repeat it once the window is actually on screen.
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak window] _ in
                guard let window, window.occlusionState.contains(.visible) else { return }
                MainActor.assumeIsolated { WindowBlur.apply(to: window) }
            }
        }

        private var occlusionObserver: NSObjectProtocol?
        private var buttonObservers: [NSObjectProtocol] = []

        /// Close, minimize and zoom, centered StageMetrics.topBar / 2 below
        /// the window's top edge.
        static func alignButtons(in window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
                let center = StageMetrics.topBar / 2
                var frame = button.frame
                frame.origin.y = container.isFlipped
                    ? center - frame.height / 2
                    : container.bounds.height - center - frame.height / 2
                frame.origin.x = (kind == .closeButton ? 14 : (kind == .miniaturizeButton ? 34 : 54))
                if button.frame != frame { button.setFrameOrigin(frame.origin) }
            }
        }

        deinit {
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            buttonObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        @objc private func closeWindow() {
            guard let model else { return }
            Store.shared.requestCloseWindow(model)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ConfigView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum WindowBlur {
    /// `background-blur` from the user's ghostty config: absent/false → 0,
    /// bare `true` → ghostty's default of 20, otherwise the number.
    static let radius: Int32 = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty/config").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("background-blur") else { continue }
            let value = line.split(separator: "=", maxSplits: 1)
                .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if let number = Int32(value) { return number }
            return value == "false" ? 0 : 20
        }
        return 0
    }()

    /// Private window-server API (CGSSetWindowBackgroundBlurRadius) — the
    /// standard trick used by terminal emulators for translucent windows.
    static func apply(to window: NSWindow) {
        guard radius > 0 else { return }
        typealias GetConnection = @convention(c) () -> UInt32
        typealias SetBlur = @convention(c) (UInt32, UInt32, Int32) -> Int32
        guard let handle = dlopen(nil, RTLD_LAZY),
              let connSym = dlsym(handle, "CGSDefaultConnectionForThread"),
              let blurSym = dlsym(handle, "CGSSetWindowBackgroundBlurRadius")
        else { return }
        let connection = unsafeBitCast(connSym, to: GetConnection.self)()
        _ = unsafeBitCast(blurSym, to: SetBlur.self)(
            connection, UInt32(window.windowNumber), radius
        )
    }
}
