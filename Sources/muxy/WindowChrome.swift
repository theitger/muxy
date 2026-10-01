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
            window.isRestorable = false
            window.tabbingMode = .disallowed
            // Closing goes through muxy, which confirms running work and
            // ends the window's sessions with it.
            if let close = window.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closeWindow)
            }
            if let topLeft = model.pendingTopLeft {
                model.pendingTopLeft = nil
                window.setFrameTopLeftPoint(topLeft)
            }
            WindowBlur.apply(to: window)
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
