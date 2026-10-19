import SwiftUI

/// A result as a card shows it: plain values, like WingFace.
struct ResultFace: Equatable {
    var summary: String?
    var tests: TestRun.Outcome?
    /// The PR's checks: live from the PR poll when there is one.
    var checks: Checks?
}

extension Workspace {
    /// Its result for the card; nil until one was built.
    var resultFace: ResultFace? {
        guard let result = Results.shared.result(for: self) else { return nil }
        let checks = context.pr != nil ? context.checks : result.pr?.checks
        return ResultFace(
            summary: result.summary.map { PlainText.shortened($0, to: 160) },
            tests: result.tests?.outcome,
            checks: checks == Checks.none ? nil : checks
        )
    }
}

/// The card's outcome line once the agent is done: test and CI icons,
/// then what the agent says it did.
struct ResultLine: View {
    let face: ResultFace
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 5) {
            if let tests = face.tests { TestsIcon(outcome: tests, size: size) }
            if let checks = face.checks { ChecksIcon(checks: checks, size: size) }
            Text(face.summary ?? L("No summary"))
                .font(.system(size: size))
                .foregroundStyle(face.summary == nil ? Theme.textDim : Theme.textBody)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct TestsIcon: View {
    let outcome: TestRun.Outcome
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "testtube.2")
            .font(.system(size: size - 1, weight: .semibold))
            .foregroundStyle(tone)
            .help(Self.label(outcome))
            .accessibilityLabel(Self.label(outcome))
    }

    private var tone: Color {
        switch outcome {
        case .passed: Theme.greenTone.strong
        case .failed: Theme.redTone.strong
        case .unclear: Theme.textDim
        }
    }

    static func label(_ outcome: TestRun.Outcome) -> String {
        switch outcome {
        case .passed: L("Tests passed")
        case .failed: L("Tests failed")
        case .unclear: L("Tests ran, outcome unclear")
        }
    }
}

struct ChecksIcon: View {
    let checks: Checks
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size - 1, weight: .semibold))
            .foregroundStyle(tone)
            .help(Self.label(checks))
            .accessibilityLabel(Self.label(checks))
    }

    private var symbol: String {
        switch checks {
        case .passed: "checkmark.seal.fill"
        case .failed: "xmark.seal.fill"
        case .pending: "clock"
        case .none: "seal"
        }
    }

    private var tone: Color {
        switch checks {
        case .passed: Theme.greenTone.strong
        case .failed: Theme.redTone.strong
        case .pending: Theme.blue.strong
        case .none: Theme.textDim
        }
    }

    static func label(_ checks: Checks) -> String {
        switch checks {
        case .passed: L("CI passed")
        case .failed: L("CI failed")
        case .pending: L("CI running")
        case .none: L("No CI checks")
        }
    }
}

/// Opens and closes the result panel (⌘I).
struct ResultButton: View {
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject private var results = Results.shared
    @State private var hovered = false

    var body: some View {
        let open = results.isPanelOpen(in: window)
        // Plain shells have no result to show.
        if open || results.source(in: workspace) != nil { button(open: open) }
    }

    private func button(open: Bool) -> some View {
        Button { results.togglePanel(in: window) } label: {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                Text(L("Result"))
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(open || hovered ? Theme.textPrimary : Theme.textDim)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(open ? Theme.fillActive : (hovered ? Theme.fillHover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Result (⌘I)"))
        .accessibilityLabel(open ? L("Hide result") : L("Show result"))
        .onHover { hovered = $0 }
    }
}

/// The stage's result panel: slides in over the terminal's right edge
/// when open.
struct ResultOverlay: View {
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject private var results = Results.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if results.isPanelOpen(in: window) {
                let session = results.source(in: workspace)
                ResultPanel(
                    result: session.flatMap { results.bySession[$0.id] },
                    building: session.map { results.building.contains($0.id) } ?? false,
                    hasAgent: session != nil,
                    livePR: workspace.context.pr,
                    liveChecks: workspace.context.checks,
                    refresh: { if let session { results.refresh(session) } },
                    close: { results.closePanel(in: window) }
                )
                .padding(10)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The PR poll moved the checks on: their names follow.
        .onChange(of: workspace.context.checks) {
            if results.isPanelOpen(in: window), let session = results.source(in: workspace) { results.refresh(session) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // Closed, the terminal underneath gets every click.
        .allowsHitTesting(results.isPanelOpen(in: window))
    }
}

/// The panel itself, drawn from plain values like the wings' cards.
struct ResultPanel: View {
    let result: SessionResult?
    let building: Bool
    let hasAgent: Bool
    /// The session's PR and its checks as the PR poll knows them now.
    var livePR: Int?
    var liveChecks: Checks = .none
    var refresh: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // Bounded (the summary is cut short): no scrolling needed.
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.textPrimary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(L("Result"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if building {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: L("Refresh result"), action: refresh)
                .accessibilityLabel(L("Refresh result"))
                .disabled(!hasAgent)
            IconButton(symbol: "xmark", help: L("Close result (⌘I)"), action: close)
                .accessibilityLabel(L("Close result"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 40)
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    label(L("What the agent did"))
                    Text(result.summary.map { PlainText.shortened($0, to: 700) } ?? L("The agent left no summary in this turn."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(result.summary == nil ? Theme.textDim : Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 9) {
                    testsRow(result.tests)
                    changesRow(result.changes)
                    prRows(result.pr)
                }
                actions(result.pr)
                Text(L("Updated %@", result.updated.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textFaint)
            }
        } else if building {
            Text(L("Reading the agent's log …"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
        } else {
            Text(!hasAgent
                ? L("No agent runs in this session.")
                : L("No result yet. It appears when the agent finishes a turn."))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
    }

    private func row(@ViewBuilder icon: () -> some View, _ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon().frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Theme.mono(size: 10.5))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func testsRow(_ tests: TestRun?) -> some View {
        if let tests {
            row(icon: { TestsIcon(outcome: tests.outcome, size: 13) }, TestsIcon.label(tests.outcome), detail: tests.command)
        } else {
            row(icon: { Image(systemName: "testtube.2").foregroundStyle(Theme.textFaint) }, L("No tests ran in this turn"))
        }
    }

    @ViewBuilder
    private func changesRow(_ changes: DiffCount?) -> some View {
        if let changes {
            row(
                icon: { Image(systemName: "doc.on.doc").foregroundStyle(Theme.textDim) },
                changes.files == 0 ? L("No files changed")
                    : changes.files == 1 ? L("1 file changed") : L("%d files changed", changes.files),
                detail: changes.files == 0 ? nil : "+\(changes.insertions) −\(changes.deletions)"
            )
        }
    }

    @ViewBuilder
    private func prRows(_ pr: PullRequestResult?) -> some View {
        if let pr {
            row(icon: { Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.textDim) }, prText(pr))
            // Checks as the PR poll knows them, names from the last build.
            let checks = livePR == pr.number ? liveChecks : pr.checks
            row(
                icon: { ChecksIcon(checks: checks, size: 13) },
                ChecksIcon.label(checks),
                detail: checks == .failed && !pr.failing.isEmpty ? pr.failing.joined(separator: ", ") : nil
            )
        } else {
            row(icon: { Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.textFaint) }, L("No pull request yet"))
        }
    }

    private func prText(_ pr: PullRequestResult) -> String {
        switch pr.state {
        case .open: L("Pull request #%d is open", pr.number)
        case .merged: L("Pull request #%d is merged", pr.number)
        case .closed: L("Pull request #%d is closed", pr.number)
        }
    }

    @ViewBuilder
    private func actions(_ pr: PullRequestResult?) -> some View {
        if let pr, let url = URL(string: pr.url), let checks = URL(string: pr.checksURL) {
            HStack(spacing: 8) {
                PanelButton(title: L("Open PR"), symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                PanelButton(title: L("Open checks"), symbol: "arrow.up.right") { NSWorkspace.shared.open(checks) }
            }
        }
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovered ? Theme.fillActive : Theme.fillHover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
