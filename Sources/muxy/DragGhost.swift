import AppKit
import SwiftUI

/// A small floating label that follows the pointer while a tab or session
/// is dragged outside its window — the preview of where it will land.
@MainActor
enum DragGhost {
    private static var panel: NSPanel?

    static func update(title: String, from window: NSWindow?) {
        let point = NSEvent.mouseLocation
        let inside = window?.frame.contains(point) ?? false
        guard !inside else {
            hide()
            return
        }
        let panel = panel ?? makePanel()
        if panel.title != title {
            panel.title = title
            let host = NSHostingView(rootView: Label(title: title))
            host.frame.size = host.fittingSize
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
        }
        panel.setFrameTopLeftPoint(NSPoint(x: point.x + 10, y: point.y - 10))
        panel.orderFrontRegardless()
    }

    static func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        self.panel = panel
        return panel
    }

    private struct Label: View {
        let title: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .padding(12)
        }
    }
}
