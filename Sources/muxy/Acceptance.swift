import Foundation

/// Human acceptance of a pull request's exact commit. Quorum and landing
/// start only after this receipt exists for the current PR head.
@MainActor
final class Acceptance: ObservableObject {
    static let shared = Acceptance()
    private static let storageKey = "acceptedPullRequestHeads"

    enum Readiness: Equatable {
        case checking
        case ready(String)
        case noHead
        case changed
        case uncommitted
        case unavailable
        case criteriaUnavailable
        case criteriaPending

        var head: String? {
            if case let .ready(head) = self { return head }
            return nil
        }

        var message: String {
            switch self {
            case .checking: L("Checking the current commit …")
            case let .ready(head): L("Ready to accept commit %@", String(head.prefix(8)))
            case .noHead: L("Waiting for the pull request commit from GitHub")
            case .changed: L("The local commit differs from the pull request. Refresh and inspect it again.")
            case .uncommitted: L("Commit the remaining changes before accepting this result.")
            case .unavailable: L("Could not verify the commit. Try reloading.")
            case .criteriaUnavailable: L("Could not refresh the linked issue's acceptance criteria. Try reloading.")
            case .criteriaPending: L("Check the acceptance criteria for this commit before approving.")
            }
        }
    }

    @Published private(set) var heads: [String: String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        heads = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    nonisolated static func key(repo: String, pr: Int) -> String {
        "\(repo.lowercased())#\(pr)"
    }

    func covers(_ workspace: Workspace) -> Bool {
        let context = workspace.context
        guard TaskLedger.shared.problem == nil else { return false }
        guard let repo = context.repo, let pr = context.pr else { return false }
        return covers(repo: repo, pr: pr, head: context.prHead)
            && TaskLedger.shared.record(for: TaskTarget(workspace: workspace)).satisfied(at: context.prHead)
    }

    func covers(repo: String, pr: Int, head: String?) -> Bool {
        guard let head else { return false }
        return heads[Self.key(repo: repo, pr: pr)] == head.lowercased()
    }

    func acceptedHead(repo: String, pr: Int) -> String? {
        heads[Self.key(repo: repo, pr: pr)]
    }

    func invalidate(repo: String, pr: Int) {
        heads.removeValue(forKey: Self.key(repo: repo, pr: pr))
        defaults.set(heads, forKey: Self.storageKey)
    }

    nonisolated static func acceptedOpenPullRequest(_ lookup: Git.Lookup, number: Int, acceptedHead: String?) -> Git.PullRequest? {
        guard let acceptedHead,
              case let .found(pull) = lookup,
              pull.number == number, pull.state == .open,
              pull.head?.lowercased() == acceptedHead.lowercased()
        else { return nil }
        return pull
    }

    /// The linked issue is the source of imported criteria. A failed refresh
    /// is not equivalent to an issue with no checklist.
    func synchronizeCriteria(for workspace: Workspace) async -> Bool {
        guard TaskLedger.shared.problem == nil else { return false }
        let target = TaskTarget(workspace: workspace)
        guard let issue = target.issue else { return true }
        guard let checkout = workspace.context.checkout else { return false }
        let fresh = await Task.detached(priority: .userInitiated) {
            Issues.view(issue.number, repo: issue.repo, in: checkout, fresh: true)
        }.value
        guard case let .found(value) = fresh else { return false }
        return TaskLedger.shared.update(target.id) {
            $0.synchronize(value, previousTitle: issue.title)
        }
    }

    /// Check both GitHub's PR head and the local working tree. The approval
    /// button must not certify a screenshot of files that are not in the PR.
    nonisolated static func readiness(checkout: String, expected: String?) -> Readiness {
        guard let expected, expected.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else { return .noHead }
        guard let head = Shell.run(WorkState.git, ["rev-parse", "HEAD"], in: checkout),
              head.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else { return .unavailable }
        guard head.lowercased() == expected.lowercased() else { return .changed }
        let state = Shell.execute(WorkState.git, ["status", "--porcelain", "--untracked-files=normal"], in: checkout, timeout: 30)
        guard state.status == 0 else { return .unavailable }
        return state.output.isEmpty ? .ready(head.lowercased()) : .uncommitted
    }

    /// Recheck at the click, since the agent can change the branch while the
    /// human is looking at the preview. Returns the fresh state for the UI.
    func approve(_ workspace: Workspace, inspectedHead: String?) async -> Readiness {
        guard TaskLedger.shared.problem == nil else { return .unavailable }
        let context = workspace.context
        guard let repo = context.repo, let pr = context.pr, let checkout = context.checkout else { return .noHead }
        guard let inspectedHead, inspectedHead == context.prHead?.lowercased() else { return .changed }
        let live = await Task.detached(priority: .userInitiated) {
            Git.pullRequest(in: checkout)
        }.value
        let expected: String
        switch live {
        case let .found(pull) where pull.number == pr && pull.state == .open && pull.head?.lowercased() == inspectedHead:
            expected = inspectedHead
        case .unknown:
            return .unavailable
        default:
            return .changed
        }
        let state = await Task.detached(priority: .userInitiated) {
            Self.readiness(checkout: checkout, expected: expected)
        }.value
        guard case let .ready(head) = state else { return state }
        guard workspace.context.repo == repo, workspace.context.pr == pr,
              workspace.context.prHead?.lowercased() == head else { return .changed }
        guard await synchronizeCriteria(for: workspace) else { return .criteriaUnavailable }
        guard TaskLedger.shared.record(for: TaskTarget(workspace: workspace)).satisfied(at: head) else { return .criteriaPending }
        let finalState = await Task.detached(priority: .userInitiated) {
            Self.readiness(checkout: checkout, expected: expected)
        }.value
        guard case let .ready(finalHead) = finalState else { return finalState }
        let finalLive = await Task.detached(priority: .userInitiated) {
            Git.pullRequest(in: checkout)
        }.value
        switch finalLive {
        case let .found(pull) where pull.number == pr && pull.state == .open && pull.head?.lowercased() == finalHead:
            break
        case .unknown:
            return .unavailable
        default:
            return .changed
        }
        guard finalHead == head, workspace.context.repo == repo, workspace.context.pr == pr,
              workspace.context.prHead?.lowercased() == finalHead else { return .changed }
        heads[Self.key(repo: repo, pr: pr)] = finalHead
        defaults.set(heads, forKey: Self.storageKey)
        return finalState
    }
}
