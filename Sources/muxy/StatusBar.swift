import SwiftUI

/// Along the window's foot: every session's state and what muxy itself
/// is doing, counted. Quiet when nothing happens; colors only where they
/// mean something.
struct StatusBar: View {
    @ObservedObject var store: Store
    @ObservedObject var window: WindowModel
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var landing = Landing.shared
    @ObservedObject private var hub = HubModel.shared
    @ObservedObject private var usage = Usage.shared

    var body: some View {
        // Session states change without the store noticing: look each second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in bar }
    }

    private var bar: some View {
        let sessions = store.workspaces
        let working = sessions.filter { $0.agent == .working }.count
        let waiting = sessions.filter { $0.agent == .blocked }.count
        let failed = sessions.filter { $0.agent == .failed }.count
        let collisions = Set(radar.byCheckout.values.flatMap { $0 }.filter { !$0.withBase }.flatMap(\.files)).count
        let behind = radar.byCheckout.values.flatMap { $0 }.filter(\.withBase).count
        let running = quorum.byKey.values.filter(\.running).count
        let landings = landing.steps.values.filter(\.isActive).count
        return HStack(spacing: 14) {
            if working > 0 { pip(Theme.blue.strong, working, L("working")) }
            if waiting > 0 { pip(Theme.orange.strong, waiting, L("need you"), button: { store.toggleInbox() }) }
            if failed > 0 { pip(Theme.redTone.strong, failed, L("failed")) }
            if working + waiting + failed == 0 {
                Text(sessions.isEmpty ? L("No open sessions")
                     : sessions.count == 1 ? L("1 open session") : L("%d open sessions", sessions.count))
                    .foregroundStyle(Theme.textMuted)
            }
            fact("arrow.triangle.merge", collisions, collisions == 1 ? L("file collides") : L("files collide"),
                 tone: collisions > 0 ? Theme.orange.strong : nil)
            fact("arrow.down.to.line", behind, L("behind base"), tone: nil)
            fact("shield", proofs.running.count, L("checking"), tone: proofs.running.isEmpty ? nil : Theme.blue.strong)
            fact("person.3", running, "quorum", tone: running > 0 ? Theme.blue.strong : nil)
            fact("airplane", landings, L("landing"), tone: landings > 0 ? Theme.blue.strong : nil)
            Spacer(minLength: 8)
            limits("Claude", usage.claude)
            limits("Codex", usage.codex)
            if let login = hub.account.login {
                Text("gh:" + login).foregroundStyle(Theme.textFaint)
            }
            Button { window.goHome() } label: {
                Text("⌘H " + L("Start")).foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .font(Theme.label(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Theme.sidebar)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 11)
    }

    /// A square of the state's color and its count; dim at zero.
    @ViewBuilder
    private func pip(_ tone: Color, _ count: Int, _ label: String, button: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: 5) {
            Circle().fill(count > 0 ? tone : Theme.textFaint.opacity(0.5)).frame(width: 6, height: 6)
            Text("\(String(count)) \(label)").foregroundStyle(count > 0 ? Theme.textBody : Theme.textFaint)
        }
        if let button {
            Button(action: button) { content }.buttonStyle(.plain).help(L("Inbox (⇧⌘J)"))
        } else {
            content
        }
    }

    @ViewBuilder
    private func fact(_ symbol: String, _ count: Int, _ label: String, tone: Color?) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Icon(symbol, size: 9)
                Text("\(String(count)) \(label)")
            }
            .foregroundStyle(tone ?? Theme.textMuted)
        }
    }

    /// An agent's limits: how much of each window is used, red when it
    /// is nearly gone, when it frees up on hover.
    @ViewBuilder
    private func limits(_ agent: String, _ windows: [UsageWindow]) -> some View {
        if !windows.isEmpty {
            HStack(spacing: 4) {
                Text(agent).foregroundStyle(Theme.textFaint)
                ForEach(windows, id: \.name) { window in
                    Text("\(window.name) \(Int(window.used.rounded()))%")
                        .foregroundStyle(window.used >= Usage.ceiling ? Theme.redTone.strong
                            : window.used >= 80 ? Theme.orange.strong : Theme.textDim)
                        .monospacedDigit()
                }
            }
            .help(windows.map { window in
                window.resets.map { L("%@: %d%% used, resets %@", window.name, Int(window.used.rounded()),
                                      $0.formatted(date: .abbreviated, time: .shortened)) }
                    ?? L("%@: %d%% used", window.name, Int(window.used.rounded()))
            }.joined(separator: "\n"))
        }
    }

}
