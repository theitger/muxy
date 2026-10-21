import SwiftUI

struct TaskGitHubRequest: Hashable {
    var repo: String
    var issue: Int?
    var pr: Int?
}

struct TaskGitHubSnapshot {
    var issue: Issue?
    var issueState: String?
    var pullRequest: Git.PullRequest?
    var problem = false

    static func issueState(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? String, ["OPEN", "CLOSED"].contains(state) else { return nil }
        return state
    }

    static func pullRequest(from data: Data) -> Git.PullRequest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? String, ["OPEN", "CLOSED", "MERGED"].contains(state),
              let checks = json["statusCheckRollup"] as? [[String: Any]] else { return nil }
        // Unknown check formats must never turn into a green CI indicator.
        for check in checks {
            if let status = check["status"] as? String {
                guard ["QUEUED", "IN_PROGRESS", "COMPLETED", "WAITING", "PENDING", "REQUESTED"].contains(status) else { return nil }
                if status == "COMPLETED" {
                    guard let conclusion = check["conclusion"] as? String,
                          ["SUCCESS", "NEUTRAL", "SKIPPED", "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"].contains(conclusion),
                          conclusion != "STALE" else { return nil }
                }
            } else {
                guard let state = check["state"] as? String,
                      ["SUCCESS", "PENDING", "EXPECTED", "ERROR", "FAILURE"].contains(state) else { return nil }
            }
        }
        return Git.pullRequest(from: json)
    }

    static func load(_ request: TaskGitHubRequest) -> Self {
        guard let gh = Shell.find("gh") else { return Self(problem: true) }
        var snapshot = Self()
        if let number = request.issue {
            if case let .found(issue) = Issues.view(number, repo: request.repo, in: Paths.home, fresh: true) {
                snapshot.issue = issue
                snapshot.issueState = issue.state
            }
            if snapshot.issueState == nil { snapshot.problem = true }
        }
        if let pr = request.pr {
            let result = Shell.execute(gh, ["pr", "view", String(pr), "--repo", request.repo, "--json", "number,state,headRefOid,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup"], in: Paths.home, timeout: 15)
            if result.status == 0 { snapshot.pullRequest = pullRequest(from: Data(result.output.utf8)) }
            if snapshot.pullRequest?.number != pr { snapshot.pullRequest = nil; snapshot.problem = true }
        }
        return snapshot
    }
}

struct TaskGitHubStatus: View {
    let request: TaskGitHubRequest
    @Binding var issueState: String?
    var onIssue: (Issue) -> Void = { _ in }
    var onInitialLoading: (Bool) -> Void = { _ in }
    @State private var snapshot = TaskGitHubSnapshot()
    @State private var checked: Date?
    @State private var checking = false
    @State private var refresh = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if checked == nil {
                SkeletonGroup {
                    HStack(spacing: 16) {
                        SkeletonBar(width: 42, height: 12)
                        if request.issue != nil { SkeletonBar(width: 85, height: 12) }
                        SkeletonBar(width: 100, height: 12)
                        if request.pr != nil { SkeletonBar(width: 80, height: 12) }
                        Spacer(minLength: 0)
                    }.frame(height: 16)
                }
            } else {
                HStack(spacing: 16) {
                    Text("GitHub").foregroundStyle(Theme.textDim)
                    if let issue = request.issue, let url = URL(string: "https://github.com/\(request.repo)/issues/\(issue)") {
                        Link(destination: url) {
                            Text(snapshot.issueState == "OPEN" ? L("Issue open") : snapshot.issueState == "CLOSED" ? L("Issue closed") : L("Issue status unknown"))
                        }
                    }
                    if let number = request.pr, let url = URL(string: "https://github.com/\(request.repo)/pull/\(number)") {
                        Link(destination: url) {
                            Text("#\(number) · " + prLabel)
                        }
                        Text(ciLabel).foregroundStyle(snapshot.pullRequest?.checks == .failed ? Theme.red : Theme.textMuted)
                    } else {
                        Text(L("No pull request linked")).foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: 0)
                    if let checked { Text(checked, style: .time).foregroundStyle(Theme.textDim) }
                    Button { refresh = UUID() } label: { Icon("arrow.clockwise", size: 11) }
                        .buttonStyle(.plain).help(L("Refresh")).disabled(checking)
                }
            }
            if snapshot.problem {
                Text(L("GitHub could not be fully refreshed. Unknown states need checking."))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .font(.system(size: 12)).foregroundStyle(Theme.textBody)
        .task(id: refresh) {
            repeat {
                checking = true
                if checked == nil { onInitialLoading(true) }
                let value = await Task.detached(priority: .utility) { TaskGitHubSnapshot.load(request) }.value
                guard !Task.isCancelled else { return }
                snapshot = value
                issueState = value.issueState
                if let issue = value.issue { onIssue(issue) }
                checked = Date()
                checking = false
                onInitialLoading(false)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private var prLabel: String {
        guard let pr = snapshot.pullRequest else { return L("PR status unknown") }
        switch pr.state {
        case .merged: return L("Merged")
        case .closed: return L("Closed")
        case .open: return pr.isDraft ? L("Draft") : L("Open")
        }
    }

    private var ciLabel: String {
        guard let pr = snapshot.pullRequest else { return L("CI unknown") }
        switch pr.checks {
        case .none: return L("No checks")
        case .pending: return L("CI running")
        case .failed: return L("CI failed")
        case .passed: return L("CI passed")
        }
    }
}
