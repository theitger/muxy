import SwiftUI

/// Run details shared by the result panel and the hub detail page.
struct QuorumRunView: View {
    let key: String
    private let source: QuorumStatus?
    private let fullWidth: Bool
    @ObservedObject private var watch = QuorumWatch.shared
    @State private var run: QuorumRun?
    @State private var warning: String?
    @State private var selected: String?
    @State private var loaded = false

    init(key: String, initialRun: QuorumRun? = nil, source: QuorumStatus? = nil, fullWidth: Bool = false) {
        self.key = key
        self.source = source
        self.fullWidth = fullWidth
        _run = State(initialValue: initialRun)
        _selected = State(initialValue: initialRun.flatMap { Self.focus($0)?.id })
        _loaded = State(initialValue: initialRun != nil)
    }

    private var status: QuorumStatus? {
        guard let source else { return watch.byKey[key] }
        let current = watch.byKey[key]
        return current?.runDirectory == source.runDirectory ? current ?? source : source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning { prose(warning) }
            if let run {
                Text(headline(run))
                    .font(.system(size: 12)).foregroundStyle(Theme.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                Text(facts(run)).font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                if fullWidth {
                    expandedSteps(run)
                } else {
                    compactSteps(run)
                }
                HStack(spacing: 8) {
                    if let pr = status?.number, let log = Quorum.latestLog(pr: pr) {
                        SmallButton(title: L("Log"), symbol: "terminal") {
                            Quorum.showLog(log, in: status.flatMap { HubModel.shared.checkout(of: $0.repo) } ?? Paths.home)
                        }
                    }
                    if let url = status?.url {
                        SmallButton(title: "PR", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                    }
                }
            } else if loaded {
                prose(L("quorum left nothing to show for this run."))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: status) {
            await load()
            while !Task.isCancelled, status?.running == true {
                do { try await Task.sleep(for: .seconds(4)) }
                catch { return }
                await load()
            }
        }
    }

    private func compactSteps(_ run: QuorumRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                ForEach(run.steps) { step in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            selected = selected == step.id ? nil : step.id
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                StateMark(word: "", tone: Self.tone(step), size: 11, dot: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.title(step)).foregroundStyle(Theme.textBody)
                                    Text(Self.subtitle(step)).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Icon(selected == step.id ? "chevron.down" : "chevron.right", size: 8)
                                    .foregroundStyle(Theme.textDim)
                            }
                            .font(.system(size: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(selected == step.id ? L("Expanded") : L("Collapsed"))
                        if selected == step.id {
                            stepDetail(run, step)
                                .padding(.leading, 15)
                        }
                    }
                }
        }
    }

    private func expandedSteps(_ run: QuorumRun) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(run.steps) { step in
                            Button { selected = step.id } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    StateMark(word: "", tone: Self.tone(step), size: 12, dot: true)
                                        .padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(Self.title(step)).font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(Theme.textBody)
                                        Text(Self.subtitle(step)).font(.system(size: 11.5))
                                            .foregroundStyle(Theme.textDim).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(selected == step.id ? Theme.fillActive : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected == step.id ? .isSelected : [])
                            .id(step.id)
                        }
                    }
                    .padding(.trailing, 12)
                }
                .onChange(of: loaded) {
                    if let selected { proxy.scrollTo(selected, anchor: .center) }
                }
            }
            .frame(width: 280)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                if let step = run.steps.first(where: { $0.id == selected }) ?? Self.focus(run) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Self.title(step)).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(Self.subtitle(step)).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        }
                        stepDetail(run, step)
                        if let model = step.kind == .review ? run.reviewModel : run.fixModel {
                            Text(model).font(Theme.mono(size: 11)).foregroundStyle(Theme.textDim)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                    .padding(.trailing, 8)
                    .padding(.vertical, 10)
                }
            }
            .id(selected)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 8)
    }

    private func load() async {
        guard let status else {
            loaded = true
            return
        }
        let (found, note) = await Task.detached(priority: .userInitiated) {
            (QuorumRun.load(status), QuorumCompat.warning(for: status.runDirectory))
        }.value
        guard !Task.isCancelled else { return }
        run = found
        warning = note
        if let found, !loaded || (selected != nil && !found.steps.contains(where: { $0.id == selected })) {
            selected = Self.focus(found)?.id
        }
        loaded = true
    }

    /// What to show first: what it is doing, or else what is still open,
    /// or else how it ended.
    static func focus(_ run: QuorumRun) -> QuorumRun.Step? {
        run.steps.last(where: \.running)
            ?? (run.latestReview?.open ?? 0 > 0 ? run.latestReview : nil)
            ?? run.steps.last
    }

    /// The one line that says where it stands.
    private func headline(_ run: QuorumRun) -> String {
        let status = run.status
        if status.running {
            if let step = run.steps.last(where: \.running) { return Self.doing(step, maxRounds: status.maxRounds) }
            return status.summary
        }
        if status.succeeded {
            let (fixed, disputed) = run.resolved
            if disputed > 0 {
                return fixed > 0 ? L("Clean after %d fixed and %d disputed findings", fixed, disputed)
                    : disputed == 1 ? L("Clean because 1 finding was disputed, not fixed")
                    : L("Clean because %d findings were disputed, not fixed", disputed)
            }
            return fixed > 0 ? L("Clean: %d findings fixed in %d rounds", fixed, run.rounds) : L("Clean")
        }
        if status.interrupted { return L("Stopped before it finished") }
        if let open = run.latestReview?.open, open > 0, status.outcome == nil || status.converged {
            return open == 1 ? L("1 finding open") : L("%d findings open", open)
        }
        return L("Stopped: %@", QuorumStatus.why(status.reason))
    }

    private func facts(_ run: QuorumRun) -> String {
        var parts: [String] = []
        if run.status.kind == .babysit {
            let max = run.status.maxRounds.map { " / \($0)" } ?? ""
            parts.append(L("Round %@", "\(run.rounds)\(max)"))
            let commits = run.steps.flatMap(\.commits).count
            if commits > 0 { parts.append(commits == 1 ? L("1 commit") : L("%d commits", commits)) }
        }
        if let ci = run.ci { parts.append(ci == "green" ? L("CI green") : L("CI: %@", ci)) }
        if let started = run.started {
            let end = run.ended ?? Date()
            parts.append(Self.duration(end.timeIntervalSince(started)))
            parts.append(L("since %@", started.formatted(date: .omitted, time: .shortened)))
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(max(minutes, 1)) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func title(_ step: QuorumRun.Step) -> String {
        let number = step.number.map(String.init) ?? ""
        switch step.kind {
        case .review: return L("Review %@", number)
        case .fix: return L("Fix round %@", number)
        case .testFix: return L("Test fix %@", number)
        case .pushFix: return L("Push fix %@", number)
        case .ciFix: return L("CI fix %@", number)
        case .suggestions: return L("Suggestions")
        case .ci: return "CI"
        case .end: return L("Result")
        }
    }

    static func subtitle(_ step: QuorumRun.Step) -> String {
        switch step.kind {
        case .review:
            if step.running {
                return step.stage == "aggregate" ? L("merges the findings")
                    : step.stage == "verify" ? L("checks them against the code")
                    : L("%d of %d reviewers done", step.reviewersDone, step.reviewers)
            }
            return counts(step)
        case .fix, .testFix, .pushFix, .ciFix, .suggestions:
            if step.running { return L("in progress") }
            if step.commits.isEmpty, step.dispute != nil { return L("disputed, no commit") }
            return step.commits.isEmpty ? L("no commit") : step.commits.count == 1 ? subject(step.commits[0])
                : L("%d commits", step.commits.count)
        case .ci:
            return step.running ? L("waiting") : step.ok == true ? L("green") : (step.summary ?? "")
        case .end:
            return step.date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    /// "7981f2b507 fix(staff): …" → its subject.
    static func subject(_ commit: String) -> String {
        commit.split(separator: " ", maxSplits: 1).last.map(String.init) ?? commit
    }

    static func counts(_ step: QuorumRun.Step) -> String {
        var parts: [String] = []
        if step.blockers > 0 { parts.append(step.blockers == 1 ? L("1 blocker") : L("%d blockers", step.blockers)) }
        if step.critical > 0 { parts.append(L("%d critical", step.critical)) }
        if step.suggestions > 0 { parts.append(step.suggestions == 1 ? L("1 suggestion") : L("%d suggestions", step.suggestions)) }
        return parts.isEmpty ? L("nothing found") : parts.joined(separator: " · ")
    }

    static func tone(_ step: QuorumRun.Step) -> Color {
        if step.running { return Theme.blue.strong }
        switch step.kind {
        case .review: return step.blockers > 0 ? Theme.redTone.strong : step.critical > 0 ? Theme.orange.strong : Theme.greenTone.strong
        case .ci, .end: return step.ok == true ? Theme.greenTone.strong : step.ok == false ? Theme.orange.strong : Theme.textDim
        default: return step.commits.isEmpty ? (step.dispute != nil ? Theme.yellow.strong : Theme.textDim) : Theme.textBody
        }
    }

    static func doing(_ step: QuorumRun.Step, maxRounds: Int?) -> String {
        let round = step.number.map { n in maxRounds.map { L("Round %d of %d", n, $0) } ?? L("Round %d", n) }
        let what: String = switch step.kind {
        case .review: subtitle(step)
        case .fix: L("the agent fixes the findings")
        case .testFix: L("the agent fixes failing tests")
        case .pushFix: L("the agent makes it pushable")
        case .ciFix: L("the agent fixes CI")
        case .suggestions: L("the agent takes in suggestions")
        case .ci: L("waits for CI")
        case .end: ""
        }
        return [step.kind == .review ? round : nil, what].compactMap { $0 }.joined(separator: ": ")
    }

    // MARK: Detail

    @ViewBuilder
    private func stepDetail(_ run: QuorumRun, _ step: QuorumRun.Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(step.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textDim)
                if let head = step.head {
                    Text(head).font(Theme.mono(size: 10)).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
                if let file = step.file {
                    SmallButton(title: step.kind == .review ? L("Report") : L("Log")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: file))
                    }
                }
            }
            switch step.kind {
            case .review: reviewDetail(step)
            case .end: endDetail(run, step)
            case .ci: prose(step.running ? L("quorum waits for CI on the pushed head.") : L("CI: %@", step.summary ?? ""))
            default: fixDetail(step)
            }
        }
    }

    @ViewBuilder
    private func reviewDetail(_ step: QuorumRun.Step) -> some View {
        if step.running {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.subtitle(step)).font(.system(size: 12.5)).foregroundStyle(Theme.textBody)
                ProgressView(value: Double(step.reviewersDone), total: Double(max(step.reviewers, 1)))
                    .frame(maxWidth: 280)
            }
        } else {
            if step.reviewers > 0 {
                Text(L("%d of %d reviewers", step.reviewersDone, step.reviewers))
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            if let summary = step.summary { prose(summary) }
            ForEach(QuorumRun.Finding.Severity.allCases, id: \.self) { severity in
                let items = step.findings.filter { $0.severity == severity }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(Self.name(severity), tone: Theme.textMuted)
                        ForEach(items, id: \.self) { FindingRow(finding: $0, tone: Self.tone(severity)) }
                    }
                }
            }
        }
    }

    static func name(_ severity: QuorumRun.Finding.Severity) -> String {
        switch severity {
        case .blocker: L("Blockers")
        case .critical: L("Critical")
        case .suggestion: L("Suggestions")
        case .question: L("Questions")
        }
    }

    static func tone(_ severity: QuorumRun.Finding.Severity) -> Color {
        switch severity {
        case .blocker: Theme.redTone.strong
        case .critical: Theme.orange.strong
        case .suggestion, .question: Theme.textMuted
        }
    }

    @ViewBuilder
    private func fixDetail(_ step: QuorumRun.Step) -> some View {
        if step.running {
            prose(L("The agent is working on it. Its commits and what it says about them show here when it is done."))
        }
        if !step.commits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(L("Commits"))
                ForEach(step.commits, id: \.self) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(commit.split(separator: " ").first.map(String.init) ?? "").font(Theme.mono(size: 11)).foregroundStyle(Theme.textDim)
                        Text(Self.subject(commit)).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        } else if !step.running {
            prose(L("No commit: nothing to change, or the agent judged the findings not to be real."))
        }
        if let summary = step.summary {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(L("What the agent says"))
                MarkdownText(text: summary)
            }
        }
        if let dispute = step.dispute {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(L("Disputed findings"), tone: Theme.textMuted)
                MarkdownText(text: dispute)
            }
        }
    }

    @ViewBuilder
    private func endDetail(_ run: QuorumRun, _ step: QuorumRun.Step) -> some View {
        prose(headline(run))
        if let reason = step.reason, !run.status.succeeded || reason.contains("description") {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(L("quorum says"))
                Text(reason).font(Theme.mono(size: 11)).foregroundStyle(Theme.textBody)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.textBody)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct FindingRow: View {
    let finding: QuorumRun.Finding
    let tone: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tone).frame(width: 5, height: 5).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                if let location = finding.location {
                    Text(location).font(Theme.mono(size: 11)).foregroundStyle(Theme.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                MarkdownText(text: finding.text)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Markdown as quorum and its agents write it: paragraphs, lists, inline
/// code and emphasis. Block by block, so lists keep their lines.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.bullet {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Theme.textDim)
                        inline(block.text)
                    }
                } else {
                    inline(block.text)
                }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.textBody)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> some View {
        let styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(styled).fixedSize(horizontal: false, vertical: true)
    }

    private var blocks: [(bullet: Bool, text: String)] {
        var result: [(Bool, String)] = []
        // A blank line ends a paragraph; a line right after one continues it.
        var open = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                open = false
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append((true, String(line.dropFirst(2))))
                open = true
            } else if line.hasPrefix("#") {
                result.append((false, "**" + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**"))
                open = false
            } else if open, let previous = result.last {
                result[result.count - 1].1 = previous.1 + " " + line
            } else {
                result.append((false, line))
                open = true
            }
        }
        return result
    }
}

/// Entry point from a pull request on the board.
struct QuorumDetailsButton: View {
    let status: QuorumStatus

    var body: some View {
        Button(L("Details")) {
            (Store.shared.activeWindow ?? Store.shared.windows.first)?.openQuorumRun(status)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11)).foregroundStyle(Theme.textDim)
        .help(L("Every review and fix of this run"))
    }
}

struct QuorumRunPage: View {
    let status: QuorumStatus
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
                Button(action: back) {
                    HStack(spacing: 5) {
                        Icon("chevron.left", size: 10)
                        Text(L("Reviews"))
                    }
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.repo + (status.number.map { " #\($0)" } ?? ""))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    Text(status.title ?? status.summary)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                QuorumRunView(key: status.key, source: status, fullWidth: true)
                    .id(status.runDirectory ?? status.key)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
