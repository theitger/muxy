import SwiftUI
import GhosttyTerminal

/// ⌘F in a terminal: Ghostty's own scrollback search. Ghostty searches on
/// a thread of its own, highlights every match and scrolls to the selected
/// one; muxy only shows the field and the count.
@MainActor
final class TerminalSearch: ObservableObject {
    @Published var needle: String {
        didSet { if needle != oldValue { schedule() } }
    }
    /// Matches in the whole scrollback; nil until Ghostty has counted.
    @Published fileprivate(set) var total: Int?
    /// Zero-based, as Ghostty reports it; nil before the first ⌘G.
    @Published fileprivate(set) var selected: Int?
    /// Bumped to pull keyboard focus back into the field.
    @Published fileprivate(set) var focusRequest = 0

    private weak var session: TerminalSession?
    private var pending: DispatchWorkItem?

    fileprivate init(session: TerminalSession, needle: String) {
        self.session = session
        self.needle = needle
        if !needle.isEmpty { schedule() }
    }

    /// Like Ghostty: one or two letters match half the scrollback, so short
    /// needles wait for a pause in typing.
    private func schedule() {
        pending?.cancel()
        let needle = needle
        let work = DispatchWorkItem { [weak self] in
            self?.session?.perform("search:" + needle)
        }
        pending = work
        if needle.isEmpty || needle.count >= 3 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func next() { session?.perform("navigate_search:next") }
    func previous() { session?.perform("navigate_search:previous") }
    func close() { session?.endSearch() }

    /// "3/12", "-/12" before a match is selected.
    var count: String? {
        guard !needle.isEmpty, let total else { return nil }
        if total == 0 { return L("No matches") }
        return "\(selected.map { String($0 + 1) } ?? "-")/\(total)"
    }
}

extension TerminalSession {
    /// ⌘F: opens the field, or focuses it again when it is already open.
    func startSearch(needle: String? = nil) {
        if let search {
            if let needle { search.needle = needle }
        } else {
            search = TerminalSearch(session: self, needle: needle ?? "")
        }
        search?.focusRequest += 1
    }

    /// Esc or the close button: Ghostty drops its highlights, the keyboard
    /// goes back to the terminal.
    func endSearch() {
        guard search != nil else { return }
        search = nil
        perform("end_search")
        terminalView.window?.makeFirstResponder(terminalView)
    }

    @discardableResult
    fileprivate func perform(_ action: String) -> Bool {
        terminalView.currentSurface?.performBindingAction(action) ?? false
    }
}

extension TerminalSession: TerminalSurfaceSearchDelegate {
    /// ⌘E (search for the selection) and any `start_search` keybind from
    /// the Ghostty config arrive here; ⌘F itself is muxy's (Store.handleKey).
    func terminalDidStartSearch(needle: String?) {
        startSearch(needle: needle)
    }

    /// Ghostty's own Esc binding ended it while the terminal had focus.
    func terminalDidEndSearch() {
        search = nil
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        search?.total = total
    }

    func terminalDidUpdateSearchSelected(_ index: Int?) {
        search?.selected = index
    }
}

/// The find field over the top right of the terminal on stage.
struct SearchOverlay: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        ZStack {
            if let search = session.search {
                FindBar(search: search)
                    .padding(.top, 10)
                    .padding(.trailing, 14)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(Theme.ease, value: session.search == nil)
    }
}

private struct FindBar: View {
    @ObservedObject var search: TerminalSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .padding(.leading, 8)
                .accessibilityHidden(true)
            TextField(L("Find in terminal"), text: $search.needle)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 170)
                .padding(.leading, 4)
                .focused($focused)
                .onSubmit { search.next() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    search.previous()
                    return .handled
                }
                .onExitCommand { search.close() }
            if let count = search.count {
                Text(count)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 4)
                    .accessibilityLabel(L("Matches: %@", count))
            }
            // Ghostty's order: "next" walks up, from the newest output to
            // the oldest.
            IconButton(symbol: "chevron.up", help: L("Next Match (⌘G)")) { search.next() }
                .accessibilityLabel(L("Next Match"))
            IconButton(symbol: "chevron.down", help: L("Previous Match (⇧⌘G)")) { search.previous() }
                .accessibilityLabel(L("Previous Match"))
            IconButton(symbol: "xmark", help: L("Close (esc)")) { search.close() }
                .accessibilityLabel(L("Close Search"))
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .onAppear { focused = true }
        .onChange(of: search.focusRequest) { focused = true }
    }
}
