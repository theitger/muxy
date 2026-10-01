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

    /// Open PR of the directory's current branch and the state of its
    /// checks, via gh.
    static func pullRequest(in directory: String) -> (number: Int, checks: Checks)? {
        guard let gh = Shell.find("gh"),
              let output = Shell.run(
                  gh, ["pr", "view", "--json", "number,state,statusCheckRollup"], in: directory
              ),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              json["state"] as? String == "OPEN",
              let number = json["number"] as? Int
        else { return nil }
        let rollup = json["statusCheckRollup"] as? [[String: Any]] ?? []
        return (number, checks(from: rollup))
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
