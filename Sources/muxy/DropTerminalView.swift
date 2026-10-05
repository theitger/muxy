import AppKit
import GhosttyTerminal

/// The terminal view plus what Ghostty.app adds on top of libghostty for
/// drag & drop: dropped files arrive as shell-escaped paths, dropped text
/// as itself — typed at the prompt, never executed.
final class DropTerminalView: TerminalView {
    private static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = Self.text(from: sender.draggingPasteboard) else { return false }
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(self)
            self.sendText(text)
        }
        return true
    }

    /// Ghostty's NSPasteboard.getOpinionatedStringContents: each item's
    /// file path (escaped) or string, space-separated.
    static func text(from pasteboard: NSPasteboard) -> String? {
        let strings = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               url.isFileURL {
                return escape(url.path)
            }
            return item.string(forType: .string)
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }

    /// Ghostty.Shell.escape: backslash before every shell-sensitive character.
    static func escape(_ path: String) -> String {
        var result = path
        for char in "\\ ()[]{}<>\"'`!#$&;|*?\t" {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}
