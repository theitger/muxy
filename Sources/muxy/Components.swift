import SwiftUI

/// Rounded icon tile that says what a session is and whether it wants you:
///
/// - branch / folder: a plain shell in a git checkout / anywhere else
/// - sparkle (blue, pulsing): Claude is working
/// - text cursor: Claude is open and waiting for your next prompt
/// - checkmark (green): Claude finished while you were elsewhere
/// - raised hand (orange): Claude is blocked on you
/// - triangle (red): the turn died on an API error
/// - bell (orange): anything else rang
struct SessionTile: View {
    let agent: AgentState
    let attention: Bool
    var isGit = false
    var size: CGFloat = 28

    private var look: (symbol: String, tone: Theme.Tone) {
        switch (agent, attention) {
        case (.blocked, _): return ("hand.raised.fill", Theme.orange)
        case (.failed, _): return ("exclamationmark.triangle.fill", Theme.redTone)
        case (.working, _): return ("sparkle", Theme.blue)
        case (.idle, true): return ("checkmark", Theme.greenTone)
        case (.idle, false): return ("text.cursor", Theme.neutral)
        case (.none, true): return ("bell.fill", Theme.orange)
        case (.none, false): return (isGit ? "arrow.triangle.branch" : "folder", Theme.neutral)
        }
    }

    var body: some View {
        let look = look
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(look.tone.soft)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: look.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(look.tone.strong)
                    // The only motion in the sidebar, and only while work runs.
                    .symbolEffect(.pulse, isActive: agent == .working)
            }
            .animation(.easeOut(duration: 0.2), value: look.symbol)
    }
}

/// Status pill: soft tint, strong text.
struct Badge: View {
    let text: String
    var tone: Theme.Tone = Theme.neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(tone.strong)
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(Capsule().fill(tone.soft))
    }
}

/// The PR number, tinted by how close it is to mergeable: blue checks
/// running, yellow red-but-being-fixed, red failed or conflicting, grey
/// draft or held back by GitHub, green ready.
struct PRBadge: View {
    let pr: Int?
    let status: PRStatus

    var body: some View {
        if let pr {
            let label = "#\(pr)"
            Group {
                switch status {
                case .none: Badge(text: label)
                case .running: Badge(text: label, tone: Theme.blue, symbol: "circle.dotted")
                case .fixing: Badge(text: label, tone: Theme.yellow, symbol: "wrench.adjustable.fill")
                case .failed: Badge(text: label, tone: Theme.redTone, symbol: "xmark")
                case .conflicts: Badge(text: label, tone: Theme.redTone, symbol: "arrow.triangle.merge")
                case .draft: Badge(text: label, symbol: "pencil")
                case .waiting: Badge(text: label, symbol: "hourglass")
                case .ready: Badge(text: label, tone: Theme.greenTone, symbol: "checkmark")
                }
            }
            .help(help)
        }
    }

    private var help: String {
        switch status {
        case .none: L("No checks")
        case .running: L("Checks running")
        case .fixing: L("Checks failed, being fixed")
        case .failed: L("Checks failed")
        case .conflicts: L("Merge conflicts")
        case .draft: L("Draft")
        case let .waiting(reason):
            switch reason {
            case .behind: L("Checks passed, branch out of date")
            case .reviewRequired: L("Checks passed, review required")
            case .changesRequested: L("Checks passed, changes requested")
            case .blocked: L("Checks passed, merge blocked")
            case .unknown, .clean, .conflicting: L("Checks passed, mergeability unknown")
            }
        case .ready: L("Ready to merge")
        }
    }
}

/// A keyboard key.
struct Kbd: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}
