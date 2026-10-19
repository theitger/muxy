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

/// Everything beyond the agent's own result the panel shows, as plain
/// values: muxy's checks, collisions, turns, quorum, landing.
struct PanelExtras {
    var proof: ProofResult?
    var proofRunning: Proofs.Running?
    var hasChecks = false
    /// Each collision with the other side's name.
    var collisions: [(collision: Collision, title: String)] = []
    /// Finished turns, newest first.
    var turns: [Checkpoint] = []
    var quorum: QuorumStatus?
    var quorumInstalled = false
    var landing: Landing.Step?
    var canLand = false
    var restoring = false
}

/// What the panel's buttons do.
struct PanelActions {
    var runProof: () -> Void = {}
    var cancelProof: () -> Void = {}
    var sendFailures: () -> Void = {}
    var review: (ReviewModel.Scope) -> Void = { _ in }
    var restore: (Checkpoint) -> Void = { _ in }
    var quorum: (QuorumStatus.Kind) -> Void = { _ in }
    var openReport: () -> Void = {}
    var tellAgent: (Collision, String) -> Void = { _, _ in }
    var land: () -> Void = {}
    var cancelLanding: () -> Void = {}
}

/// The stage's result panel: slides in over the terminal's right edge
/// when open.
struct ResultOverlay: View {
    @ObservedObject var window: WindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject private var results = Results.shared
    @ObservedObject private var proofs = Proofs.shared
    @ObservedObject private var turns = Turns.shared
    @ObservedObject private var radar = Radar.shared
    @ObservedObject private var quorum = QuorumWatch.shared
    @ObservedObject private var landing = Landing.shared

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
                    extras: extras,
                    actions: actions(session: session),
                    refresh: {
                        if let session { results.refresh(session) }
                        turns.refresh(workspace.context.checkout)
                    },
                    close: { results.closePanel(in: window) }
                )
                .padding(10)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .onAppear { turns.refresh(workspace.context.checkout) }
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

    private var extras: PanelExtras {
        let checkout = workspace.context.checkout
        return PanelExtras(
            proof: proofs.result(for: checkout),
            proofRunning: checkout.flatMap { proofs.running[$0] },
            hasChecks: workspace.context.root.map { !ProofCheck.load(root: $0).isEmpty } ?? false,
            collisions: radar.collisions(for: checkout).map { ($0, $0.withBase ? $0.other : radar.title(of: $0.other)) },
            turns: turns.checkpoints(for: checkout).filter { $0.moment == .after },
            quorum: quorum.status(for: workspace),
            quorumInstalled: Quorum.isInstalled,
            landing: landing.step(for: workspace),
            canLand: landing.canLand(workspace),
            restoring: checkout.map { turns.restoring.contains($0) } ?? false
        )
    }

    private func actions(session: TerminalSession?) -> PanelActions {
        let checkout = workspace.context.checkout
        let root = workspace.context.root
        return PanelActions(
            runProof: {
                if let checkout, let root { proofs.run(checkout: checkout, root: root, session: session) }
            },
            cancelProof: { if let checkout { proofs.cancel(checkout: checkout) } },
            sendFailures: {
                if let result = proofs.result(for: checkout), let agent = agentSession { Proofs.sendFailures(result, to: agent) }
            },
            review: { scope in window.openReview(workspace, scope: scope) },
            restore: { checkpoint in
                guard let checkout else { return }
                if workspace.sessions.contains(where: { $0.agent == .working }) {
                    window.show(L("The agent is working: wait for its turn to end"))
                    return
                }
                turns.restore(checkpoint, in: checkout) { done in
                    window.show(done ? L("Files are back to that turn") : L("Couldn't go back"))
                }
            },
            quorum: { kind in quorum.start(kind, in: workspace) },
            openReport: {
                if let report = quorum.status(for: workspace)?.report { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }
            },
            tellAgent: { collision, title in
                guard let agent = agentSession else { return }
                let files = collision.files.prefix(20).map { "- \($0)" }.joined(separator: "\n")
                let text = collision.withBase
                    ? "Your branch conflicts with \(collision.other) in these files:\n\(files)\n\nMerge \(collision.other) into this branch now (git fetch first), resolve the conflicts keeping both sides' intent, run the relevant tests and commit."
                    : "Another session (\"\(title)\", branch work in \(collision.other)) changes the same lines as you in:\n\(files)\n\nKeep your changes in these files minimal and self-contained so both can merge; say which of your changes there could move elsewhere."
                RemoteState.type(text, enter: true, into: agent)
            },
            land: { landing.land(workspace) },
            cancelLanding: { landing.cancel(workspace) }
        )
    }

    private var agentSession: TerminalSession? {
        workspace.sessions.first { $0.kind != nil && $0.agent != .none }
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
    var extras = PanelExtras()
    var actions = PanelActions()
    var refresh: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            // As tall as it needs; scrolls only when the stage is shorter.
            ViewThatFits(in: .vertical) {
                padded
                ScrollView { padded }.scrollIndicators(.never)
            }
        }
        .frame(width: 340)
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

    private var padded: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 16) {
            if let result {
                VStack(alignment: .leading, spacing: 5) {
                    label(L("What the agent did"))
                    Text(result.summary.map { PlainText.shortened($0, to: 700) } ?? L("The agent left no summary in this turn."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(result.summary == nil ? Theme.textDim : Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                proofSection(claimed: result.tests)
                VStack(alignment: .leading, spacing: 9) {
                    changesRow(result.changes)
                    prRows(result.pr)
                    quorumRow
                }
                collisionSection
                turnsSection
                landSection
                actions(result.pr)
                Text(L("Updated %@", result.updated.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textFaint)
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
                proofSection(claimed: nil)
                collisionSection
            }
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

    // MARK: Proof

    /// muxy's own run of the checks, against what the agent says it ran.
    @ViewBuilder
    private func proofSection(claimed: TestRun?) -> some View {
        if extras.hasChecks || extras.proof != nil || claimed != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    label(L("Proof"))
                    Spacer()
                    if extras.proofRunning != nil {
                        SmallButton(title: L("Stop"), action: actions.cancelProof)
                    } else if extras.hasChecks {
                        SmallButton(title: extras.proof == nil ? L("Run checks") : L("Run again"), action: actions.runProof)
                    }
                }
                if let claimed {
                    row(icon: { TestsIcon(outcome: claimed.outcome, size: 13) },
                        L("Agent says: %@", TestsIcon.label(claimed.outcome).lowercased()), detail: claimed.command)
                }
                if let running = extras.proofRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini).frame(width: 16)
                        Text(running.count > 0 ? L("muxy runs %@ (%d of %d)", running.check, running.index, running.count) : running.check)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Text(running.since, style: .timer)
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.textDim)
                    }
                } else if let proof = extras.proof {
                    ForEach(Array(proof.entries.enumerated()), id: \.offset) { _, entry in
                        row(icon: { ProofIcon(outcome: entry.outcome) }, proofText(entry),
                            detail: entry.outcome == .failed ? entry.tail.split(separator: "\n").last.map(String.init) : nil)
                    }
                    if let claimed, claimed.outcome == .passed, proof.verdict == .failed {
                        Text(L("The agent's claim doesn't hold: muxy's checks fail."))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.redTone.strong)
                    }
                    if proof.verdict == .failed {
                        SmallButton(title: L("Send failures to the agent"), symbol: "paperplane.fill", prominent: true, action: actions.sendFailures)
                    }
                } else if extras.hasChecks {
                    Text(L("Not run on these files yet."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    private func proofText(_ entry: ProofResult.Entry) -> String {
        let time = entry.seconds >= 1 ? " · " + Duration.seconds(entry.seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)) : ""
        switch entry.outcome {
        case .passed: return L("%@ passed", entry.name) + time
        case .failed: return L("%@ failed", entry.name) + time
        case .skipped: return L("%@: nothing it checks changed", entry.name)
        case .cancelled: return L("%@ stopped", entry.name)
        }
    }

    // MARK: Collisions

    @ViewBuilder
    private var collisionSection: some View {
        if !extras.collisions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                label(L("Collisions"))
                ForEach(Array(extras.collisions.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        row(icon: {
                            Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.orange.strong)
                        }, item.collision.withBase
                            ? L("Conflicts with %@", item.title)
                            : L("Collides with “%@”", item.title),
                        detail: item.collision.files.prefix(3).joined(separator: ", ")
                            + (item.collision.files.count > 3 ? " +\(item.collision.files.count - 3)" : ""))
                        SmallButton(title: item.collision.withBase ? L("Ask the agent to merge it") : L("Tell the agent"),
                                    symbol: "paperplane") { actions.tellAgent(item.collision, item.title) }
                            .padding(.leading, 24)
                    }
                }
            }
        }
    }

    // MARK: Turns

    @ViewBuilder
    private var turnsSection: some View {
        if !extras.turns.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    label(L("Turns"))
                    Spacer()
                    if extras.restoring { ProgressView().controlSize(.mini) }
                }
                ForEach(extras.turns.prefix(6)) { turn in
                    HStack(spacing: 8) {
                        Text(turn.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(Theme.textDim)
                            .frame(width: 44, alignment: .leading)
                        Text(turn.label.isEmpty ? L("Turn") : turn.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textBody)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        IconButton(symbol: "plus.forwardslash.minus", help: L("What this turn changed")) {
                            actions.review(.turn(turn))
                        }
                        IconButton(symbol: "arrow.uturn.backward", help: L("Put the files back to this turn")) {
                            actions.restore(turn)
                        }
                    }
                    .frame(height: 26)
                }
            }
        }
    }

    // MARK: quorum & landing

    @ViewBuilder
    private var quorumRow: some View {
        if let status = extras.quorum {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if status.running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: status.isClean ? "person.3.fill" : "exclamationmark.bubble.fill")
                            .foregroundStyle(status.isClean ? Theme.greenTone.strong : Theme.orange.strong)
                    }
                }
                .frame(width: 16)
                Text(status.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                if status.report != nil {
                    SmallButton(title: L("Report"), action: actions.openReport)
                }
            }
        }
    }

    @ViewBuilder
    private var landSection: some View {
        if let step = extras.landing {
            VStack(alignment: .leading, spacing: 6) {
                label(L("Landing"))
                HStack(spacing: 8) {
                    Group {
                        switch step {
                        case .landed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.purple.strong)
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.redTone.strong)
                        case .waitingForAgent: Image(systemName: "sparkle").foregroundStyle(Theme.blue.strong)
                        default: ProgressView().controlSize(.mini)
                        }
                    }
                    .frame(width: 16)
                    Text(step.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if step.isActive {
                        SmallButton(title: L("Stop"), action: actions.cancelLanding)
                    } else if case .failed = step {
                        SmallButton(title: L("Again"), action: actions.land)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func changesRow(_ changes: DiffCount?) -> some View {
        if let changes {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(Theme.textDim).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(changes.files == 0 ? L("No files changed")
                        : changes.files == 1 ? L("1 file changed") : L("%d files changed", changes.files))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textPrimary)
                    if changes.files > 0 {
                        Text("+" + String(changes.insertions) + " −" + String(changes.deletions))
                            .font(Theme.mono(size: 10.5))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                Spacer(minLength: 4)
                if changes.files > 0 {
                    SmallButton(title: L("Review"), action: { actions.review(.lastTurn) })
                }
            }
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
        VStack(alignment: .leading, spacing: 8) {
            if let pr, pr.state == .open {
                HStack(spacing: 8) {
                    if extras.canLand, extras.landing?.isActive != true {
                        PanelButton(title: L("Land"), symbol: "airplane.arrival", prominent: true, action: actions.land)
                            .help(L("Up to date, checks, push, review, merge: one step after the other"))
                    }
                    if extras.quorumInstalled, extras.quorum?.running != true {
                        Menu {
                            Button(L("Review and fix (babysit)")) { actions.quorum(.babysit) }
                            Button(L("Review only")) { actions.quorum(.review) }
                        } label: {
                            Text("quorum").font(.system(size: 12, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                }
            }
            if let pr, let url = URL(string: pr.url), let checks = URL(string: pr.checksURL) {
                HStack(spacing: 8) {
                    PanelButton(title: L("Open PR"), symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                    PanelButton(title: L("Open checks"), symbol: "arrow.up.right") { NSWorkspace.shared.open(checks) }
                }
            }
        }
    }
}

/// Pass, fail, skip as a small icon.
struct ProofIcon: View {
    let outcome: ProofResult.Outcome

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tone)
    }

    private var symbol: String {
        switch outcome {
        case .passed: "checkmark.shield.fill"
        case .failed: "xmark.shield.fill"
        case .skipped: "minus.circle"
        case .cancelled: "stop.circle"
        }
    }

    private var tone: Color {
        switch outcome {
        case .passed: Theme.greenTone.strong
        case .failed: Theme.redTone.strong
        default: Theme.textDim
        }
    }
}

/// A compact text button for panel rows.
struct SmallButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(prominent ? Theme.bg : Theme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? Theme.textPrimary.opacity(hovered ? 0.85 : 1) : (hovered ? Theme.fillActive : Theme.fillHover))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct PanelButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            }
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Theme.bg : Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Theme.textPrimary.opacity(hovered ? 0.85 : 1) : (hovered ? Theme.fillActive : Theme.fillHover))
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
