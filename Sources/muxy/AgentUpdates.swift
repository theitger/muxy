import SwiftUI

/// Agent notifications also exist outside repositories. Keep those reachable
/// from Start and Needs you, using the same attention flags as the Dock/phone.
struct AgentUpdates: View {
    @ObservedObject var store: Store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let items = Inbox.items(in: store).filter {
                $0.workspace.context.repo == nil || $0.rank == 2
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Agent updates")).font(UI.heading).foregroundStyle(Theme.textPrimary)
                    ForEach(items) { item in
                        Button {
                            store.select(item.workspace, session: item.session)
                            store.window(of: item.workspace)?.bringToFront()
                        } label: {
                            HStack(spacing: 12) {
                                SessionTile(agent: item.session.agent, attention: true, kind: item.session.kind)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.workspace.title).font(UI.control).foregroundStyle(Theme.textPrimary)
                                    Text(item.why).font(UI.metadata).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                Icon("arrow.right", size: 14).foregroundStyle(Theme.textMuted)
                            }.padding(14).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(RoundedRectangle(cornerRadius: UI.radius).strokeBorder(Theme.border))
                    }
                }
            }
        }
    }
}
