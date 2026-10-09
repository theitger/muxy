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

    static let radius: CGFloat = 10

    private var blocked: Bool { face.agent == .blocked }
    private var leaning: Bool { detailed && !hovered && !onStage }

    var body: some View {
        if detailed {
            card
        } else {
            row
        }
    }

    // MARK: Detailed

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SessionTile(agent: face.agent, attention: face.attention, isGit: face.isGit, size: 20)
                Text(face.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                PRBadge(pr: face.pr, status: face.prStatus)
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 7)

            preview

            ticker
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 9)
        }
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
                    .strokeBorder(Theme.textPrimary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .opacity(face.isQuiet && !hovered && !onStage ? 0.62 : 1)
        .rotation3DEffect(
            .degrees(leaning ? 13 : 0), axis: (x: 0, y: 1, z: 0),
            anchor: .leading, perspective: 0.3
        )
        .scaleEffect(leaning ? 0.97 : 1, anchor: .leading)
    }

    private var preview: some View {
            VStack(alignment: .leading, spacing: 1.5) {
                ForEach(Array(face.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(Theme.mono(size: 9.5))
            .foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .bottomLeading)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
            )
            .padding(.horizontal, 8)
    }

    private var ticker: some View {
        HStack(spacing: 6) {
            switch face.agent {
            case .working:
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 10, height: 10)
            case .blocked, .failed:
                Circle().fill(tone).frame(width: 6, height: 6)
            case .idle where face.attention:
                Circle().fill(tone).frame(width: 6, height: 6)
            default:
                EmptyView()
            }
            Text(face.activity)
                .font(.system(size: 11, weight: blocked ? .semibold : .regular))
                .foregroundStyle(tone)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                ForEach(Array(face.agents.enumerated()), id: \.offset) { _, state in
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(state == .none || state == .idle ? Theme.textFaint : Theme.tone(for: state).strong)
                }
            }
        }
    }

    private var tone: Color {
        switch face.agent {
        case .blocked: Theme.orange.strong
        case .failed: Theme.redTone.strong
        case .working: Theme.blue.strong
        case .idle where face.attention: Theme.greenTone.strong
        default: Theme.textDim
        }
    }

    // MARK: Simple

    private var row: some View {
        HStack(spacing: 10) {
            SessionTile(agent: face.agent, attention: face.attention, isGit: face.isGit)
            VStack(alignment: .leading, spacing: 1) {
                Text(face.title)
                    .font(.system(size: 13, weight: onStage ? .semibold : .medium))
                    .foregroundStyle(onStage ? Theme.textPrimary : Theme.textBody)
                    .lineLimit(1)
                Text(face.activity)
                    .font(.system(size: 11))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                .frame(height: 46)
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

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let card = CGRect(
            x: rect.minX + leading, y: rect.minY,
            width: rect.width - leading - margin, height: rect.height - margin
        )
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

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(place)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
                .truncationMode(.middle)
            PRBadge(pr: pr, status: prStatus)
        }
        .lineLimit(1)
    }
}

/// "login-fix ⌘J" — someone else wants you.
struct WaitingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.orange.strong).frame(width: 6, height: 6)
            Text(text.count > 30 ? text.prefix(29) + "…" : text)
                .lineLimit(1)
            Text("⌘J").opacity(0.55)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.orange.strong)
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(Theme.orange.soft))
        .contentShape(Capsule())
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
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Kbd(keys)
            }
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textBody)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Theme.fillHover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
