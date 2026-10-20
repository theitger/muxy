import Foundation

/// GitHub owns the PR lifecycle; a successful quorum run may still be open.
enum ReviewHistory {
    enum PRState: String { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }

    struct Request: Hashable {
        var keys: [String]
        var refreshed: Date?
    }

    struct Lookup {
        var states: [String: PRState] = [:]
        var incomplete = false
    }

    struct Groups {
        var active: [QuorumStatus] = []
        var completed: [QuorumStatus] = []
    }

    static func group(_ runs: [QuorumStatus], states: [String: PRState], now: Date = Date()) -> Groups {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        var groups = Groups()
        for run in runs.sorted(by: {
            if $0.running != $1.running { return $0.running }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.key < $1.key
        }) {
            let finishedBranch = run.key.contains("#branch:") && !run.running
            if finishedBranch || states[run.key] == .merged || states[run.key] == .closed {
                if run.date >= cutoff { groups.completed.append(run) }
            } else {
                groups.active.append(run)
            }
        }
        return groups
    }

    /// Small aliased queries avoid one network request per run and pagination gaps.
    static func load(keys: [String]) -> Lookup {
        let keys = keys.filter { !$0.contains("#branch:") }
        guard !keys.isEmpty else { return Lookup() }
        guard let gh = Shell.find("gh") else { return Lookup(incomplete: true) }
        var lookup = Lookup()
        for start in stride(from: 0, to: keys.count, by: 40) {
            let batch = Array(keys[start..<min(start + 40, keys.count)])
            let fields = batch.enumerated().compactMap { index, key -> String? in
                let parts = key.split(separator: "#", omittingEmptySubsequences: false)
                guard parts.count == 2, let number = Int(parts[1]), number > 0 else { return nil }
                let repo = parts[0].split(separator: "/", omittingEmptySubsequences: false)
                // GitHub repository names cannot contain GraphQL string delimiters.
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                guard repo.count == 2, repo.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
                return "r\(index): repository(owner: \"\(repo[0])\", name: \"\(repo[1])\") { pullRequest(number: \(number)) { state } }"
            }
            guard !fields.isEmpty else { lookup.incomplete = true; continue }
            let result = Shell.execute(gh, ["api", "graphql", "-f", "query={ \(fields.joined(separator: " ")) }"], in: Paths.home, timeout: 20)
            let parsed = parse(result.output, keys: batch)
            lookup.states.merge(parsed.states) { _, new in new }
            lookup.incomplete = lookup.incomplete || parsed.incomplete || result.status != 0
        }
        return lookup
    }

    static func parse(_ output: String, keys: [String]) -> Lookup {
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let data = json["data"] as? [String: Any] else { return Lookup(incomplete: true) }
        var lookup = Lookup()
        for (index, key) in keys.enumerated() {
            guard let repo = data["r\(index)"] as? [String: Any],
                  let pr = repo["pullRequest"] as? [String: Any],
                  let raw = pr["state"] as? String, let state = PRState(rawValue: raw) else {
                lookup.incomplete = true
                continue
            }
            lookup.states[key] = state
        }
        if let errors = json["errors"] as? [Any], !errors.isEmpty { lookup.incomplete = true }
        return lookup
    }
}
