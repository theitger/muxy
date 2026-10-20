import SwiftUI

/// Everything a card in the wings shows, as plain values — the views below
/// draw only this, so they render the same with or without a live session.
struct WingFace {
    var title: String
    var agent: AgentState
    var attention: Bool
    var isGit: Bool
    var pr: Int?
    var prStatus: PRStatus
    var activity: String
    var lines: [String]
    /// One entry per tab running an agent, in tab order.
    var agents: [AgentState]
    /// What the last turn came to; shown once the agent is done.
    var result: ResultFace?
    /// The web app it runs, if any (Open app).
    var appPort: Int?
    /// Branch, or where it runs outside git.
    var subtitle: String = ""
    /// The agent the card speaks for.
    var kind: AgentKind?
    var sessionStatus: SessionSummary?

    /// The outcome line replaces the activity while nothing runs.
    var showsResult: Bool { result != nil && (agent == .idle || agent == .none) }

    var currentStatus: SessionSummary? {
        sessionStatus ?? SessionSummary.resolve(agent: agent)
    }

    var fallbackActivity: String? {
        guard currentStatus == nil, !showsResult, !activity.isEmpty else { return nil }
        return activity
    }

    /// Nothing running, nothing new: the card steps back.
    var isQuiet: Bool { agent == .none && !attention }
}

/// The wings' card. Detailed: a small window with the session's last lines
/// that leans back like Stage Manager's until pointed at. Simple: a row.
struct WingCardFace: View {
    let face: WingFace
    let detailed: Bool
    var hovered = false
    /// The session on stage: same size and place as every other card (so
    /// nothing jumps when you switch), upright and framed.
    var onStage = false
    var openDetails: (() -> Void)?

    static let radius: CGFloat = 9

    private var blocked: Bool { face.agent == .blocked }

    var body: some View {
        if detailed {
            card
        } else {
            row
        }
    }

    // MARK: Detailed

    /// What a session is, where it stands and what muxy knows about its
    /// work, as facts rather than a picture of its terminal. Its screen
    /// shows only while the agent asks you something: that is what to read.
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SessionTile(agent: face.agent, attention: face.attention, isGit: face.isGit, kind: face.kind, size: 20)
                Text(face.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                PRBadge(pr: face.pr, status: face.prStatus)
            }
            if !face.subtitle.isEmpty, face.subtitle != face.title {
                Text(face.subtitle)
                    .font(Theme.mono(size: 10.5))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            status
            if blocked, !face.lines.isEmpty {
                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(Array(face.lines.suffix(3).enumerated()), id: \.offset) { _, line in
                        Text(Theme.displayable(line)).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(Theme.mono(size: 9.5))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.orange.soft))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Theme.surfaceActive)
        )
        .overlay {
            // Blocked: orange, it wants you. On stage: the one you're in.
            if blocked {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(Theme.orange.strong.opacity(0.6), lineWidth: onStage ? 1.5 : 1)
            } else if onStage {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(Theme.textPrimary.opacity(0.55), lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(hovered ? Theme.textDim.opacity(0.6) : Theme.border, lineWidth: 1)
            }
        }
        .opacity(face.isQuiet && !hovered && !onStage ? 0.7 : 1)
    }

    @ViewBuilder private var status: some View {
        if let value = face.currentStatus {
            if let openDetails {
                Button(action: openDetails) { SessionSummaryLine(status: value) }
                    .buttonStyle(.plain).help(L("Open task details"))
            } else {
                SessionSummaryLine(status: value)
            }
        } else if face.showsResult, let result = face.result {
            ResultLine(face: result)
        } else if let activity = face.fallbackActivity {
            Text(activity)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: Simple

    private var row: some View {
        HStack(spacing: 10) {
            SessionTile(agent: face.agent, attention: face.attention, isGit: face.isGit, kind: face.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(face.title)
                    .font(.system(size: 13, weight: onStage ? .semibold : .medium))
                    .foregroundStyle(onStage ? Theme.textPrimary : Theme.textBody)
                    .lineLimit(1)
                status
            }
            Spacer(minLength: 4)
            PRBadge(pr: face.pr, status: face.prStatus)
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(onStage ? Theme.fillActive : (hovered ? Theme.fillHover : .clear))
        )
    }
}

enum StageMetrics {
    /// The stage card's corners.
    static let radius: CGFloat = 10
    /// Gutter between the stage card and the window edge.
    static let margin: CGFloat = 8
    /// The title bar: a compact toolbar's height, so the window's own
    /// buttons (centered in it by macOS) line up with muxy's.
    static let topBar: CGFloat = 40
}

/// The window with the wings out: a title bar across, the wings on the
/// left, the session in front as a card on the right.
struct StageLayout<TopBar: View, Wings: View, Stage: View>: View {
    let wingsWidth: CGFloat
    @ViewBuilder let topBar: TopBar
    @ViewBuilder let wings: Wings
    @ViewBuilder let stage: Stage

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: StageMetrics.topBar)
                .frame(maxWidth: .infinity)
                .background(Theme.sidebar)
            HStack(spacing: 0) {
                wings.frame(width: wingsWidth)
                stage
                    .padding(.trailing, StageMetrics.margin)
                    .padding(.bottom, StageMetrics.margin)
            }
            .background(
                StageGutter(leading: wingsWidth, radius: StageMetrics.radius, margin: StageMetrics.margin)
                    .fill(Theme.sidebar, style: FillStyle(eoFill: true))
                    .clipped()
            )
            // The card's corners: two half-transparent edges meeting there
            // let the window behind shine through as a thin ring. Slivers in
            // the gutter's color, a touch rounder, cover it.
            .overlay(
                StageGutter(leading: wingsWidth, radius: StageMetrics.radius + 1.5, margin: StageMetrics.margin, cornersOnly: true)
                    .fill(Theme.sidebar, style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            )
        }
    }
}

/// The wings' color around the stage card: the area minus the card. The
/// card itself stays unpainted, so the terminal's own translucent background
/// is the only layer there — exactly as in Ghostty.
struct StageGutter: Shape {
    var leading: CGFloat
    var radius: CGFloat = 10
    var margin: CGFloat = 8
    /// Only the card's four corner slivers, not the whole gutter.
    var cornersOnly = false

    func path(in rect: CGRect) -> Path {
        let card = CGRect(
            x: rect.minX + leading, y: rect.minY,
            width: rect.width - leading - margin, height: rect.height - margin
        )
        var path = Path(cornersOnly ? card : rect)
        path.addRoundedRect(in: card, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}

/// The title bar's middle: what is on stage and where it lives.
struct StageTitle: View {
    let title: String
    let place: String
    let pr: Int?
    let prStatus: PRStatus
    var prURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(place)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .truncationMode(.middle)
            Button {
                if let prURL { NSWorkspace.shared.open(prURL) }
            } label: {
                PRBadge(pr: pr, status: prStatus)
            }
            .buttonStyle(.plain)
            .disabled(prURL == nil)
        }
        .lineLimit(1)
    }
}

/// "login-fix": someone else wants you.
struct WaitingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.orange.strong).frame(width: 6, height: 6)
            Text(text.count > 30 ? text.prefix(29) + "…" : text)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.orange.strong)
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.orange.soft))
        .contentShape(Rectangle())
    }
}

/// A labelled title-bar button with its key: "+ New Session ⌘N".
struct TitleBarButton: View {
    let symbol: String
    let title: String
    let keys: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Icon(symbol, size: 10.5)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Kbd(keys)
            }
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textBody)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovered ? Theme.fillHover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
