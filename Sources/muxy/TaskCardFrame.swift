import SwiftUI

struct TaskCardHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 180 }
extension EnvironmentValues {
    var taskCardHeight: CGFloat {
        get { self[TaskCardHeightKey.self] }
        set { self[TaskCardHeightKey.self] = newValue }
    }
}
struct TaskCardHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum CardPart: Hashable { case header, actions }
private struct CardPartsPreference: PreferenceKey {
    static let defaultValue: [CardPart: CGFloat] = [:]
    static func reduce(value: inout [CardPart: CGFloat], nextValue: () -> [CardPart: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

/// Metadata stays at the top, descriptions consume spare space, actions share a bottom edge.
struct TaskCardFrame<Header: View, Actions: View>: View {
    var description: String?
    var highlighted = false
    @ViewBuilder var header: Header
    @ViewBuilder var actions: Actions
    @Environment(\.taskCardHeight) private var height
    @State private var parts: [CardPart: CGFloat] = [:]
    @State private var hovered = false

    var body: some View {
        TaskCardBodyLayout(minimumHeight: max(0, height - 28)) {
            header.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: CardPartsPreference.self, value: [.header: geometry.size.height])
                })
            GeometryReader { space in
                // Text has an intrinsic minimum line height. Do not render a
                // partial line when the card has no complete line left.
                if space.size.height >= 18 {
                    Text(TaskCardExcerpt.text(description))
                        .font(UI.metadata).foregroundStyle(Theme.textMuted)
                        .lineSpacing(3)
                        .lineLimit(max(1, Int(space.size.height / 18)))
                        .truncationMode(.tail)
                        .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
                        .clipped()
                }
            }
            .clipped().allowsHitTesting(false)
            actions.fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: CardPartsPreference.self, value: [.actions: geometry.size.height])
                })
        }
        .padding(14)
        .onPreferenceChange(CardPartsPreference.self) { parts = $0 }
        .preference(key: TaskCardHeightPreference.self,
                    value: (parts[.header] ?? 0) + (parts[.actions] ?? 0) + 42)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceActive))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(highlighted ? Theme.orange.strong.opacity(0.6) : Theme.hairline, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(Theme.textPrimary.opacity(hovered ? 0.22 : 0), lineWidth: 1))
        .onHover { hovered = $0 }
    }
}

struct TaskCardBodyLayout: Layout {
    var minimumHeight: CGFloat

    static func frames(in bounds: CGRect, header: CGFloat, actions: CGFloat) -> [CGRect] {
        let footerY = bounds.maxY - actions
        let textY = bounds.minY + header + 7
        let textHeight = max(0, floor((footerY - 7 - textY) / 18) * 18)
        return [CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: header),
                CGRect(x: bounds.minX, y: textY, width: bounds.width, height: textHeight),
                CGRect(x: bounds.minX, y: footerY, width: bounds.width, height: actions)]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 280
        let header = subviews[0].sizeThatFits(.init(width: width, height: nil)).height
        let actions = subviews[2].sizeThatFits(.init(width: width, height: nil)).height
        let offeredHeight = proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        return CGSize(width: width, height: max(minimumHeight, offeredHeight, header + actions + 14))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let header = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil)).height
        let actions = subviews[2].sizeThatFits(.init(width: bounds.width, height: nil)).height
        for (index, frame) in Self.frames(in: bounds, header: header, actions: actions).enumerated() {
            subviews[index].place(at: frame.origin, anchor: .topLeading,
                                  proposal: .init(width: frame.width, height: index == 0 ? nil : frame.height))
        }
    }
}

struct CardGitHubLink: View {
    let url: String
    var body: some View {
        Button {
            if let destination = URL(string: url) { NSWorkspace.shared.open(destination) }
        } label: {
            Icon("arrow.up.right", size: 10).foregroundStyle(Theme.textMuted).frame(width: 24, height: 22)
        }
        .buttonStyle(.plain).help(L("Open on GitHub"))
    }
}

/// Every task has one primary action and the same two utility slots.
struct TaskCardFooter<Actions: View>: View {
    let title: String
    var url: String?
    var disabled = false
    var busy = false
    let action: () -> Void
    @ViewBuilder var more: Actions

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                SkeletonGroup { SkeletonBar(width: 105, height: 26, radius: 6) }
            } else {
                Button(action: action) {
                    Text(title).font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 9).frame(height: 26)
                        .foregroundStyle(Theme.bg)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.textPrimary))
                }
                .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1).help(title)
            }
            Spacer(minLength: 8)
            Menu { more } label: {
                Icon("ellipsis", size: 12).foregroundStyle(Theme.textMuted).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("More"))
            if let url { CardGitHubLink(url: url).frame(width: 26, height: 26) }
            else { Color.clear.frame(width: 26, height: 26).accessibilityHidden(true) }
        }
        .frame(height: 26)
    }
}
