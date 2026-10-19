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

    var body: some View {
        let sessions = store.workspaces
        let working = sessions.filter { $0.agent == .working }.count
        let waiting = sessions.filter { $0.agent == .blocked }.count
        let failed = sessions.filter { $0.agent == .failed }.count
        let idle = sessions.filter { $0.agent == .idle }.count
        let collisions = Set(radar.byCheckout.values.flatMap { $0 }.filter { !$0.withBase }.flatMap(\.files)).count
        let behind = radar.byCheckout.values.flatMap { $0 }.filter(\.withBase).count
        let running = quorum.byKey.values.filter(\.running).count
        let landings = landing.steps.values.filter(\.isActive).count
        HStack(spacing: 14) {
            pip(Theme.blue.strong, working, L("working"))
            pip(Theme.orange.strong, waiting, L("need you"), button: waiting > 0 ? { store.jumpToAttention() } : nil)
            pip(Theme.redTone.strong, failed, L("failed"))
            pip(Theme.textDim, idle, L("idle"))
            divider
            fact("arrow.triangle.merge", collisions, collisions == 1 ? L("file collides") : L("files collide"),
                 tone: collisions > 0 ? Theme.orange.strong : nil)
            fact("arrow.down.to.line", behind, L("behind base"), tone: nil)
            fact("shield", proofs.running.count, L("checking"), tone: proofs.running.isEmpty ? nil : Theme.blue.strong)
            fact("person.3", running, "quorum", tone: running > 0 ? Theme.blue.strong : nil)
            fact("airplane", landings, L("landing"), tone: landings > 0 ? Theme.blue.strong : nil)
            Spacer(minLength: 8)
            if let login = hub.account.login {
                Text("gh:" + login).foregroundStyle(Theme.textFaint)
            }
            Button { window.showHub.toggle() } label: {
                Text("⇧⌘H " + L("hub")).foregroundStyle(window.showHub ? Theme.textPrimary : Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .font(Theme.label(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
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
            Button(action: button) { content }.buttonStyle(.plain).help(L("Next one waiting (⌘J)"))
        } else {
            content
        }
    }

    @ViewBuilder
    private func fact(_ symbol: String, _ count: Int, _ label: String, tone: Color?) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text("\(String(count)) \(label)")
            }
            .foregroundStyle(tone ?? Theme.textMuted)
        }
    }
}
