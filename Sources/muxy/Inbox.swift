import SwiftUI

/// A numbered choice an agent offers on screen: Claude Code's and Codex's
/// permission prompts ("❯ 1. Yes", "  2. Yes, and don't ask again …",
/// "  3. No, and tell Claude what to do differently (esc)"). Both take the
/// digit as the answer.
struct Choice: Equatable {
    var number: Int
    var label: String
    /// The one the agent's cursor (❯, ›) is on.
    var selected = false
}

enum Choices {
    /// The last run of options numbered 1, 2, 3 … near the bottom of the
    /// screen; none when the screen shows no such menu.
    static func parse(_ screen: String) -> [Choice] {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(30)
        var best: [Choice] = []
        var run: [Choice] = []
        for line in lines {
            if let choice = choice(in: String(line)) {
                if choice.number == run.count + 1 {
                    run.append(choice)
                } else if choice.number == 1 {
                    run = [choice]
                }
                continue
            }
            // A wrapped option's second line keeps the run going.
            if !run.isEmpty, line.hasPrefix("     "), !line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if run.count >= 2 { best = run }
            run = []
        }
        if run.count >= 2 { best = run }
        return best
    }

    /// The keys from the marked choice to `target`, then Enter. Without a
    /// marked one the cursor is assumed on the first.
    static func keys(to target: Choice, in choices: [Choice]) -> [String] {
        let from = choices.first(where: \.selected)?.number ?? 1
        let delta = target.number - from
        return Array(repeating: delta > 0 ? "down" : "up", count: abs(delta)) + ["enter"]
    }

    private static func choice(in line: String) -> Choice? {
        guard let match = line.groups(#"^\s*([❯›>▶]\s*)?(\d)[.)]\s+(\S.*)$"#),
              let number = Int(match[1]) else { return nil }
        var label = match[2].trimmingCharacters(in: .whitespaces)
        // "(esc)", "(y)": the key hint, not the answer.
        if let hint = label.range(of: #"\s*\((?:esc|[a-z])\)$"#, options: .regularExpression) {
            label.removeSubrange(hint)
        }
        guard !label.isEmpty, label.count <= 120 else { return nil }
        return Choice(number: number, label: label, selected: !match[0].isEmpty)
    }
}

/// Everything that waits on you, in every window, most urgent first:
/// agents blocked on a question, turns that failed, news you haven't seen.
@MainActor
final class Inbox: ObservableObject {
    static let shared = Inbox()

    struct Item: Identifiable {
        var workspace: Workspace
        var session: TerminalSession
        var why: String
        var rank: Int
        var since: Date
        var id: TerminalSession.ID { session.id }
    }

    /// Windows whose inbox is open.
    @Published private(set) var open: Set<WindowModel.ID> = []

    func isOpen(in window: WindowModel) -> Bool { open.contains(window.id) }

    func toggle(in window: WindowModel) {
        if open.remove(window.id) == nil { open.insert(window.id) }
    }

    func close(in window: WindowModel) {
        open.remove(window.id)
    }

    static func items(in store: Store) -> [Item] {
        var items: [Item] = []
        for workspace in store.orderedWorkspaces {
            for session in workspace.sessions {
                let since = session.waitingSince ?? .distantPast
                switch session.agent {
                case .blocked:
                    items.append(Item(workspace: workspace, session: session, why: L("needs you"), rank: 0, since: since))
                case .failed:
                    items.append(Item(workspace: workspace, session: session, why: L("hit an error"), rank: 1, since: since))
                default:
                    guard session.needsAttention else { continue }
                    let why = session.notice ?? (session.agent == .idle ? L("is done") : L("has news"))
                    items.append(Item(workspace: workspace, session: session, why: why, rank: 2, since: since))
                }
            }
        }
        return items.sorted { ($0.rank, $0.since) < ($1.rank, $1.since) }
    }

    /// The screen as it is now, for its choices.
    static func choices(of session: TerminalSession) -> [Choice] {
        guard session.agent == .blocked,
              let text = session.terminalView.currentSurface?.readText(screen: false) else { return [] }
        return Choices.parse(text)
    }

    /// Answers a session without going there: text and Enter, or a choice.
    static func reply(_ text: String, to session: TerminalSession) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        RemoteState.type(trimmed, enter: true, into: session)
    }

    /// Moves the agent's cursor to the choice and confirms it, as you
    /// would with the arrow keys: both agents take that, while a typed
    /// digit means "pick" to one and "type a digit" to another.
    static func choose(_ choice: Choice, in session: TerminalSession) {
        let current = choices(of: session)
        for (index, key) in Choices.keys(to: choice, in: current).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(index)) {
                RemoteState.press(key, in: session)
            }
        }
        session.needsAttention = false
    }
}

/// The pill in the title bar: how many wait on you. A click opens the
/// inbox (⇧⌘J); ⌘J goes to the next one.
struct InboxPill: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject private var inbox = Inbox.shared

    var body: some View {
        let waiting = Inbox.items(in: store).filter { $0.workspace.id != window.selectedWorkspaceID }
        if let first = waiting.first {
            Button { inbox.toggle(in: window) } label: {
                WaitingPill(text: waiting.count == 1 ? first.workspace.title : L("%d sessions waiting", waiting.count))
            }
            .buttonStyle(.plain)
            .help(L("Inbox (⇧⌘J). Next one: ⌘J"))
            .accessibilityLabel(L("Inbox: %d waiting", waiting.count))
            .popover(isPresented: Binding(
                get: { inbox.isOpen(in: window) },
                set: { if !$0 { inbox.close(in: window) } }
            ), arrowEdge: .bottom) {
                InboxView(store: store, window: window)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

struct InboxView: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel

    var body: some View {
        // The screens behind the rows change on their own: look again each second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let items = Inbox.items(in: store)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("Waiting on you"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Kbd("⌘J")
                    Text(L("next"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if items.isEmpty {
                    Text(L("Nobody is waiting right now"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                InboxRow(item: item) {
                                    Inbox.shared.close(in: window)
                                    store.select(item.workspace, session: item.session)
                                }
                                if item.id != items.last?.id {
                                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 520)
                }
            }
            .frame(width: 420)
            .background(Theme.surface)
        }
    }
}

private struct InboxRow: View {
    let item: Inbox.Item
    let open: () -> Void
    @State private var reply = ""
    @FocusState private var focused: Bool

    var body: some View {
        let choices = Inbox.choices(of: item.session)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(tone).frame(width: 6, height: 6)
                Text(item.workspace.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(item.why)
                    .font(.system(size: 12))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if item.since != .distantPast {
                    Text(item.since, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .monospacedDigit()
                }
            }
            let place = [item.workspace.context.repo, item.workspace.subtitle].compactMap { $0 }.joined(separator: " · ")
            if !place.isEmpty {
                Text(place)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            if let lines = item.session.snapshot?.lines, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(Theme.displayable(line)).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(Theme.mono(size: 10))
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.textPrimary.opacity(0.05)))
            }
            if !choices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(choices, id: \.number) { choice in
                        Button { Inbox.choose(choice, in: item.session) } label: {
                            HStack(spacing: 6) {
                                Text("\(choice.number)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.textDim)
                                    .frame(width: 14)
                                Text(choice.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fillHover))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Answer %d: %@", choice.number, choice.label))
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(L("Reply to %@", item.workspace.title), text: $reply)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(focused ? Theme.textPrimary.opacity(0.35) : Theme.hairline, lineWidth: 1)
                    )
                IconButton(symbol: "arrow.up.circle.fill", help: L("Send (↩)"), action: send)
                    .accessibilityLabel(L("Send"))
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                IconButton(symbol: "arrow.right.circle", help: L("Go there"), action: open)
                    .accessibilityLabel(L("Go there"))
            }
        }
        .padding(14)
    }

    private func send() {
        Inbox.reply(reply, to: item.session)
        reply = ""
    }

    private var tone: Color {
        switch item.rank {
        case 0: Theme.orange.strong
        case 1: Theme.redTone.strong
        default: Theme.greenTone.strong
        }
    }
}
