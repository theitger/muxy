import Foundation

/// Blocking subprocess helpers. Callers run them off the main thread.
enum Shell {
    /// GUI apps get launchd's minimal PATH; gh & co. live in Homebrew.
    static let path: String = {
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", Paths.home + "/.local/bin"]
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return (extra + [base]).joined(separator: ":")
    }()

    static func run(_ executable: String, _ args: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func find(_ name: String) -> String? {
        path.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum Git {
    /// Repo name, checkout folder and branch for a directory — one git call.
    static func context(for directory: String) -> RepoContext {
        guard let output = Shell.run(
            "/usr/bin/git",
            ["rev-parse", "--show-toplevel", "--git-common-dir", "--abbrev-ref", "HEAD"],
            in: directory
        ) else { return .plain(directory) }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return .plain(directory) }
        let toplevel = lines[0]
        var common = lines[1]
        if !common.hasPrefix("/") {
            common = (directory as NSString).appendingPathComponent(common)
        }
        common = (common as NSString).standardizingPath
        // ".../repo/.git" → "repo"; bare repos: ".../repo.git" → "repo".
        let repoDir = (common as NSString).lastPathComponent == ".git"
            ? (common as NSString).deletingLastPathComponent
            : common
        let repo = ((repoDir as NSString).lastPathComponent as NSString).deletingPathExtension
        let branch = lines[2] == "HEAD" ? nil : lines[2]
        return RepoContext(
            repo: repo,
            root: repoDir.hasSuffix(".git") ? nil : repoDir,
            folder: (toplevel as NSString).lastPathComponent,
            branch: branch,
            pr: nil
        )
    }

    /// Branches that never carry a feature PR — skip the network call.
    static func mayHavePR(_ branch: String?) -> Bool {
        guard let branch else { return false }
        return !["main", "master", "develop", "dev", "trunk"].contains(branch)
    }

    struct PullRequest {
        var number: Int
        var checks: Checks
        var isDraft: Bool
        var mergeability: Mergeability
    }

    /// Open PR of the directory's current branch, its checks and whether
    /// GitHub would merge it, via gh.
    static func pullRequest(in directory: String) -> PullRequest? {
        guard let first = fetchPullRequest(in: directory) else { return nil }
        // GitHub computes mergeability lazily: the first ask after a push
        // often answers UNKNOWN and starts the computation — ask once more.
        guard first.mergeability == .unknown else { return first }
        Thread.sleep(forTimeInterval: 3)
        return fetchPullRequest(in: directory) ?? first
    }

    private static func fetchPullRequest(in directory: String) -> PullRequest? {
        guard let gh = Shell.find("gh"),
              let output = Shell.run(
                  gh,
                  ["pr", "view", "--json",
                   "number,state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup"],
                  in: directory
              ),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              json["state"] as? String == "OPEN",
              let number = json["number"] as? Int
        else { return nil }
        let rollup = json["statusCheckRollup"] as? [[String: Any]] ?? []
        return PullRequest(
            number: number,
            checks: checks(from: rollup),
            isDraft: json["isDraft"] as? Bool ?? false,
            mergeability: mergeability(
                mergeable: json["mergeable"] as? String ?? "",
                state: json["mergeStateStatus"] as? String ?? "",
                review: json["reviewDecision"] as? String ?? ""
            )
        )
    }

    /// GraphQL MergeableState + MergeStateStatus + ReviewDecision → one
    /// answer. UNSTABLE and DRAFT count as clean here: failing checks and
    /// drafts are judged on their own.
    static func mergeability(mergeable: String, state: String, review: String) -> Mergeability {
        if mergeable == "CONFLICTING" || state == "DIRTY" { return .conflicting }
        switch state {
        case "CLEAN", "HAS_HOOKS", "UNSTABLE", "DRAFT": return .clean
        case "BEHIND": return .behind
        case "BLOCKED":
            switch review {
            case "CHANGES_REQUESTED": return .changesRequested
            case "REVIEW_REQUIRED": return .reviewRequired
            default: return .blocked
            }
        default: return .unknown
        }
    }

    /// Check runs carry status + conclusion, commit statuses a state.
    /// One failure decides, then anything unfinished, then green.
    static func checks(from rollup: [[String: Any]]) -> Checks {
        guard !rollup.isEmpty else { return .none }
        let failing: Set = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]
        var pending = false
        for check in rollup {
            let conclusion = check["conclusion"] as? String ?? ""
            let state = check["state"] as? String ?? ""
            if failing.contains(conclusion) || failing.contains(state) { return .failed }
            if let status = check["status"] as? String, status != "COMPLETED" { pending = true }
            if state == "PENDING" || state == "EXPECTED" { pending = true }
        }
        return pending ? .pending : .passed
    }
}
