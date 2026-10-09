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
        // Nothing to say: the symbol alone, no tile around it.
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(!attention && (agent == .none || agent == .idle) ? .clear : look.tone.soft)
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

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textDim)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovered ? Theme.fillHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
    }
}

/// Which agent, or a plain shell, as its own mark in its own color.
struct AgentGlyph: View {
    let kind: AgentKind?
    var size: CGFloat = 11

    var body: some View {
        if let kind {
            Image(nsImage: Self.mark(kind))
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: size, height: size)
                .foregroundStyle(kind == .claude ? Theme.claude : Theme.codex)
        } else {
            Image(systemName: "chevron.forward")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: size, height: size)
        }
    }

    private static let marks: [AgentKind: NSImage] = Dictionary(
        uniqueKeysWithValues: AgentKind.allCases.map { kind in
            let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">"#
                + #"<path fill="black" fill-rule="evenodd" clip-rule="evenodd" d=""# + path(of: kind) + #""/></svg>"#
            let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
            image.isTemplate = true
            return (kind, image)
        }
    )

    private static func mark(_ kind: AgentKind) -> NSImage { marks[kind] ?? NSImage() }

    /// The brands' own marks (24×24).
    private static func path(of kind: AgentKind) -> String {
        switch kind {
        case .claude: "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"
        case .codex: "M 8.086 .457 a 6.105 6.105 0 0 1 3.046 -.415 c 1.333 .153 2.521 .72 3.564 1.7 a .117 .117 0 0 0 .107 .029 c 1.408 -.346 2.762 -.224 4.061 .366 l .063 .03 .154 .076 c 1.357 .703 2.33 1.77 2.918 3.198 .278 .679 .418 1.388 .421 2.126 a 5.655 5.655 0 0 1 -.18 1.631 .167 .167 0 0 0 .04 .155 5.982 5.982 0 0 1 1.578 2.891 c .385 1.901 -.01 3.615 -1.183 5.14 l -.182 .22 a 6.063 6.063 0 0 1 -2.934 1.851 .162 .162 0 0 0 -.108 .102 c -.255 .736 -.511 1.364 -.987 1.992 -1.199 1.582 -2.962 2.462 -4.948 2.451 -1.583 -.008 -2.986 -.587 -4.21 -1.736 a .145 .145 0 0 0 -.14 -.032 c -.518 .167 -1.04 .191 -1.604 .185 a 5.924 5.924 0 0 1 -2.595 -.622 6.058 6.058 0 0 1 -2.146 -1.781 c -.203 -.269 -.404 -.522 -.551 -.821 a 7.74 7.74 0 0 1 -.495 -1.283 6.11 6.11 0 0 1 -.017 -3.064 .166 .166 0 0 0 .008 -.074 .115 .115 0 0 0 -.037 -.064 5.958 5.958 0 0 1 -1.38 -2.202 5.196 5.196 0 0 1 -.333 -1.589 6.915 6.915 0 0 1 .188 -2.132 c .45 -1.484 1.309 -2.648 2.577 -3.493 .282 -.188 .55 -.334 .802 -.438 .286 -.12 .573 -.22 .861 -.304 a .129 .129 0 0 0 .087 -.087 A 6.016 6.016 0 0 1 5.635 2.31 C 6.315 1.464 7.132 .846 8.086 .457 z m -.804 7.85 a .848 .848 0 0 0 -1.473 .842 l 1.694 2.965 -1.688 2.848 a .849 .849 0 0 0 1.46 .864 l 1.94 -3.272 a .849 .849 0 0 0 .007 -.854 l -1.94 -3.393 z m 5.446 6.24 a .849 .849 0 0 0 0 1.695 h 4.848 a .849 .849 0 0 0 0 -1.696 h -4.848 z"
        }
    }
}
