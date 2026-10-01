import AppKit
import SwiftUI

/// The preview that follows the pointer while a session is dragged: a small
/// window where it would open as its own window, a sidebar row where it
/// would join another window. Its top-left is where the window will be.
@MainActor
enum DragGhost {
    /// Pointer position inside the preview (from its top-left).
    static let grabOffset = NSSize(width: 36, height: 14)

    private enum Mode: Equatable {
        case window
        case row
    }

    private static var panel: NSPanel?
    private static var shown: (id: Workspace.ID, mode: Mode)?

    static func update(_ workspace: Workspace, target: Store.DropTarget) {
        let mode: Mode
        switch target {
        case .stay:
            hide()
            return
        case .window: mode = .row
        case .newWindow: mode = .window
        }
        let panel = panel ?? makePanel()
        if shown?.id != workspace.id || shown?.mode != mode {
            shown = (workspace.id, mode)
            let host = NSHostingView(rootView: Preview(workspace: workspace, mode: mode))
            host.frame.size = host.fittingSize
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
        }
        let point = NSEvent.mouseLocation
        panel.setFrameTopLeftPoint(NSPoint(
            x: point.x - grabOffset.width - Preview.margin,
            y: point.y + grabOffset.height + Preview.margin
        ))
        panel.orderFrontRegardless()
    }

    static func hide() {
        panel?.orderOut(nil)
        shown = nil
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

    private struct Preview: View {
        @ObservedObject var workspace: Workspace
        let mode: Mode

        /// Room for the shadow around the preview.
        static let margin: CGFloat = 16

        var body: some View {
            Group {
                switch mode {
                case .window: miniWindow
                case .row: row.frame(width: 240)
                }
            }
            .padding(Self.margin)
        }

        private var row: some View {
            HStack(spacing: 10) {
                SessionTile(
                    agent: workspace.agent, attention: workspace.needsAttention,
                    isGit: workspace.context.repo != nil, size: 24
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(workspace.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textDim)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
        }

        /// A tiny muxy window: sidebar with the session, a terminal pane.
        private var miniWindow: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            Circle().fill(Theme.textPrimary.opacity(0.15)).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.bottom, 4)
                    HStack(spacing: 7) {
                        SessionTile(
                            agent: workspace.agent, attention: workspace.needsAttention,
                            isGit: workspace.context.repo != nil, size: 18
                        )
                        Text(workspace.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fillActive))
                    Spacer()
                }
                .padding(10)
                .frame(width: 112, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.surface)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([0.7, 0.5, 0.85, 0.35], id: \.self) { width in
                        Capsule()
                            .fill(Theme.textPrimary.opacity(0.08))
                            .frame(width: 150 * width, height: 4)
                    }
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.bg)
            }
            .frame(width: 300, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .opacity(0.96)
        }
    }
}
