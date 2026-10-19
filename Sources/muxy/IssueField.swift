import SwiftUI

/// The ⌘N panel's issue side: what the task field names, looked up while
/// you type, and the repository's short list after a "#". Everything runs
/// off the main thread; the panel never waits for GitHub.
@MainActor
final class IssueField: ObservableObject {
    enum Status: Equatable {
        case none
        case loading(Int)
        case found(Issue)
        case failed(String)
    }

    @Published private(set) var status: Status = .none
    @Published private(set) var suggestions: [Issue] = []
    /// The list is yours (assigned), not just the newest.
    @Published private(set) var mine = false
    @Published private(set) var highlight: Int?
    /// A repository the issue's URL names that muxy knows: the panel
    /// switches to it once per reference.
    @Published private(set) var matchedRepo: String?
    /// The issue lives in a repository you have no checkout of here.
    @Published private(set) var foreign = false

    /// The chosen repository's GitHub name.
    private(set) var targetRepo: String?
    private var ref: IssueRef?
    private var query: String?
    private var list: [Issue] = []
    private var repoPaths: [String: String] = [:]
    private var lookupToken = 0
    private var listToken = 0
    private var directory = Paths.home
    private var root: String?

    /// The issue to start with, once it is found.
    var resolved: (issue: Issue, note: String)? {
        guard case let .found(issue) = status, let ref else { return nil }
        return (issue, ref.note)
    }

    var showsSuggestions: Bool { query != nil && !suggestions.isEmpty }

    var isLoading: Bool {
        if case .loading = status { return true }
        return false
    }

    /// Learns which GitHub repository each local one is, to follow URLs.
    func learn(_ repos: [Repos.Repo]) {
        let paths = repos.map(\.path)
        Task.detached(priority: .utility) {
            let pairs = paths.compactMap { path in Issues.repo(of: path).map { ($0.lowercased(), path) } }
            await MainActor.run {
                for (slug, path) in pairs where self.repoPaths[slug] == nil { self.repoPaths[slug] = path }
            }
        }
    }

    /// The field or the repository changed.
    func update(text: String, directory: String, root: String?) {
        let moved = directory != self.directory || root != self.root
        self.directory = directory
        self.root = root
        if moved { loadList() }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed.hasPrefix("#") && !trimmed.contains(where: \.isWhitespace) ? String(trimmed.dropFirst()) : nil
        let parsed = IssueRef.parse(text)
        if parsed != ref || moved {
            if parsed?.number != ref?.number || parsed?.repo != ref?.repo { matchedRepo = nil }
            ref = parsed
            lookUp()
        }
        filter()
    }

    /// ↑/↓ through the list; false when there is none to move in.
    func move(_ step: Int) -> Bool {
        guard showsSuggestions else { return false }
        let count = suggestions.count
        highlight = highlight.map { ($0 + step + count) % count } ?? (step > 0 ? 0 : count - 1)
        return true
    }

    /// The highlighted issue, for ↩.
    var highlighted: Issue? {
        guard showsSuggestions, let highlight, suggestions.indices.contains(highlight) else { return nil }
        return suggestions[highlight]
    }

    private func filter() {
        guard let query, !isFound else {
            suggestions = []
            highlight = nil
            return
        }
        let needle = query.lowercased()
        let matching = needle.isEmpty ? list : list.filter {
            String($0.number).hasPrefix(needle) || $0.title.lowercased().contains(needle)
        }
        let shown = Array(matching.prefix(6))
        if shown != suggestions {
            suggestions = shown
            highlight = nil
        }
    }

    private var isFound: Bool {
        if case .found = status { return true }
        return false
    }

    private func loadList() {
        listToken += 1
        let token = listToken
        list = []
        targetRepo = nil
        guard let root else {
            filter()
            return
        }
        Task.detached(priority: .utility) {
            let repo = Issues.repo(of: root)
            let found = repo.flatMap { Issues.list(repo: $0, in: root) }
            await MainActor.run {
                guard token == self.listToken else { return }
                self.targetRepo = repo
                self.list = found?.issues ?? []
                self.mine = found?.mine ?? false
                self.filter()
                self.checkForeign()
            }
        }
    }

    private func lookUp() {
        lookupToken += 1
        let token = lookupToken
        guard let ref else {
            status = .none
            foreign = false
            filter()
            return
        }
        guard ref.repo != nil || root != nil else {
            status = .failed(L("#%d: choose a repository on GitHub first.", ref.number))
            return
        }
        status = .loading(ref.number)
        let directory = root ?? directory
        Task.detached(priority: .userInitiated) {
            // Typing "#12" passes "#1" on the way: wait for a pause.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard await MainActor.run(body: { token == self.lookupToken }) else { return }
            let repo = ref.repo ?? Issues.repo(of: directory)
            let answer = Issues.view(ref.number, repo: repo, in: directory)
            await MainActor.run {
                guard token == self.lookupToken else { return }
                switch answer {
                case let .found(issue):
                    self.status = .found(issue)
                    if ref.repo != nil, let path = self.repoPaths[issue.repo.lowercased()], path != self.root {
                        self.matchedRepo = path
                    }
                case .notFound:
                    self.status = .failed(L("No issue #%d in %@.", ref.number, repo ?? Paths.folderName(directory)))
                case .pullRequest:
                    self.status = .failed(L("#%d is a pull request, not an issue.", ref.number))
                case let .unavailable(reason):
                    self.status = .failed(reason)
                }
                self.filter()
                self.checkForeign()
            }
        }
    }

    private func checkForeign() {
        guard case let .found(issue) = status, let targetRepo else {
            foreign = false
            return
        }
        foreign = issue.repo.lowercased() != targetRepo.lowercased()
    }
}

/// Under the task field: the issue it names, or the list after a "#".
struct IssueAccessory: View {
    @ObservedObject var field: IssueField
    let place: String
    let pick: (Issue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chip
            if field.showsSuggestions { list }
        }
        .animation(Theme.ease, value: field.status)
        .animation(Theme.ease, value: field.suggestions)
    }

    @ViewBuilder
    private var chip: some View {
        switch field.status {
        case .none:
            EmptyView()
        case let .loading(number):
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                Text(L("Looking up #%d …", number))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 2)
        case let .found(issue):
            VStack(alignment: .leading, spacing: 4) {
                IssueRow(issue: issue, prominent: true)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.textPrimary.opacity(0.05))
                    )
                    .accessibilityElement(children: .combine)
                    .help(issue.url)
                if field.foreign {
                    Text(L("This issue is from %@, the agent starts in %@.", issue.repo, place))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.orange.strong)
                }
            }
        case let .failed(message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 2)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(field.mine ? L("Assigned to you") : L("Open issues"))
                Text("↑↓ ↩").foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
            ForEach(Array(field.suggestions.enumerated()), id: \.element.number) { index, issue in
                Button { pick(issue) } label: {
                    IssueRow(issue: issue, prominent: false)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(field.highlight == index ? Theme.fillActive : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Issue %@", issue.heading))
            }
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

/// "#42 Fix the login redirect · Open".
struct IssueRow: View {
    let issue: Issue
    var prominent = true

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: issue.isOpen ? "smallcircle.filled.circle" : "checkmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(issue.isOpen ? Theme.greenTone.strong : Theme.purple.strong)
            Text("#" + String(issue.number))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
            Text(issue.title)
                .font(.system(size: 12.5, weight: prominent ? .medium : .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if prominent {
                Badge(text: issue.isOpen ? L("Still open") : L("Already closed"), tone: issue.isOpen ? Theme.greenTone : Theme.purple)
            }
        }
    }
}
