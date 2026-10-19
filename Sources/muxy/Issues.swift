import Foundation

/// A GitHub issue a session works on. Its body only travels into the
/// agent's prompt; what is saved with the session is the rest.
struct Issue: Codable, Equatable, Hashable {
    /// "owner/name", or "host/owner/name" off github.com: what `gh --repo` takes.
    var repo: String
    var number: Int
    var title: String
    var url: String
    /// OPEN or CLOSED, as gh says it.
    var state: String
    var labels: [String] = []
    var body: String?
    /// When it was opened: the hub lists the newest first, like gh.
    var created: Date?

    var isOpen: Bool { state.uppercased() == "OPEN" }

    /// "owner" of "owner/name" (or "host/owner/name").
    var owner: String {
        let parts = repo.split(separator: "/")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : repo
    }

    /// "#42 Fix the login redirect": the session's title until it has a PR.
    var heading: String { "#\(number) \(title)" }

    /// Without the body: what a saved session keeps.
    var saved: Issue {
        var copy = self
        copy.body = nil
        return copy
    }
}

/// What the task field said, when it names an issue: "#123", a bare "123"
/// on its own, "owner/repo#123" or an issue's URL. Words after the
/// reference stay a note for the agent ("#12 keep the old API").
struct IssueRef: Equatable {
    /// nil: the chosen repository's.
    var repo: String?
    var number: Int
    var note = ""

    static func parse(_ text: String) -> IssueRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A number alone is a task nobody would write: it means the issue.
        // With anything after it ("123 tests fail") it is just a sentence.
        if trimmed.count <= 7, trimmed.allSatisfy(\.isASCIIDigit), let number = Int(trimmed), number > 0 {
            return IssueRef(repo: nil, number: number)
        }
        let token = String(trimmed.prefix { !$0.isWhitespace })
        let note = String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = token.groups(#"^#(\d{1,7})$"#), let number = Int(match[0]), number > 0 {
            return IssueRef(repo: nil, number: number, note: note)
        }
        if let match = token.groups(#"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d{1,7})$"#), let number = Int(match[1]) {
            return IssueRef(repo: match[0], number: number, note: note)
        }
        // Pull request URLs are no issue: they stay plain text.
        if let match = token.groups(#"^https?://(?:www\.)?([^/\s]+)/([^/\s]+)/([^/\s]+)/issues/(\d{1,7})(?:[/?#].*)?$"#),
           let number = Int(match[3]) {
            let host = match[0].lowercased()
            let repo = match[1] + "/" + match[2]
            return IssueRef(repo: host == "github.com" ? repo : host + "/" + repo, number: number, note: note)
        }
        return nil
    }
}

/// Issues through `gh`: one looked up, a repository's short list, the
/// repository a checkout pushes to. Blocking; call off the main thread.
/// Answers are cached for a few minutes, so the ⌘N panel never waits twice.
enum Issues {
    enum Lookup: Equatable {
        case found(Issue)
        case notFound
        /// The number is a pull request.
        case pullRequest
        /// gh missing, signed out, offline: says which.
        case unavailable(String)
    }

    static let fields = "number,title,body,url,labels,state"

    static func view(_ number: Int, repo: String?, in directory: String) -> Lookup {
        let key = "\(repo ?? directory)#\(number)"
        if let cached = cache.issue(key) { return .found(cached) }
        guard let gh = Shell.find("gh") else { return .unavailable(L("gh is not installed.")) }
        var args = ["issue", "view", String(number), "--json", fields]
        if let repo { args += ["--repo", repo] }
        let result = Shell.execute(gh, args, in: directory, timeout: 15)
        guard result.status == 0 else { return failure(result.error) }
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let issue = issue(from: json, repo: repo)
        else { return .unavailable(L("gh gave an answer muxy can't read.")) }
        // `gh issue view` shows pull requests too.
        if issue.url.contains("/pull/") { return .pullRequest }
        cache.store(issue, key: key)
        return .found(issue)
    }

    /// The repository's open issues assigned to you; none: its newest
    /// open ones. `mine` says which it is.
    static func list(repo: String, in directory: String) -> (issues: [Issue], mine: Bool)? {
        if let cached = cache.list(repo) { return cached }
        guard let gh = Shell.find("gh") else { return nil }
        let base = ["issue", "list", "--repo", repo, "--state", "open", "--limit", "8", "--json", "number,title,url,labels,state"]
        func fetch(_ extra: [String]) -> [Issue]? {
            let result = Shell.execute(gh, base + extra, in: directory, timeout: 15)
            guard result.status == 0,
                  let rows = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]]
            else { return nil }
            return rows.compactMap { issue(from: $0, repo: repo) }
        }
        guard let assigned = fetch(["--assignee", "@me"]) else { return nil }
        let answer = assigned.isEmpty ? (fetch([]).map { ($0, false) } ?? (assigned, true)) : (assigned, true)
        cache.store(answer, repo: repo)
        return answer
    }

    /// "owner/name" the checkout's origin points to (upstream, for a fork
    /// whose origin isn't on GitHub). nil off GitHub-like hosts.
    static func repo(of directory: String) -> String? {
        if let cached = cache.slug(directory) { return cached }
        var found: String?
        for remote in ["origin", "upstream"] {
            if let url = Shell.run("/usr/bin/git", ["remote", "get-url", remote], in: directory),
               let slug = slug(ofRemote: url) {
                found = slug
                break
            }
        }
        cache.store(slug: found, for: directory)
        return found
    }

    /// git@github.com:o/r.git, https://github.com/o/r, ssh://git@host:22/o/r
    /// → "o/r" ("host/o/r" off github.com).
    static func slug(ofRemote url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let host: String
        let path: String
        if let match = text.groups(#"^[a-z+]+://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$"#) {
            host = match[0]
            path = match[1]
        } else if let match = text.groups(#"^(?:[^@/]+@)?([^/:]+):(.+)$"#) {
            host = match[0]
            path = match[1]
        } else {
            return nil
        }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let repo = parts.joined(separator: "/")
        return host.lowercased() == "github.com" ? repo : host.lowercased() + "/" + repo
    }

    /// What the agent is asked: the issue itself, then one instruction,
    /// worded the same for every agent.
    /// What an issue becomes for the agent, editable in Settings. Fields
    /// in braces are filled in; one that is empty takes its line with it.
    static let defaultTemplate = """
    GitHub issue {reference}: {title}

    {url}

    {labels}

    {body}

    {note}

    Work on this issue. When you open the pull request, write "Closes {reference}" in its description.
    """

    static let templateKey = "issuePromptTemplate"

    /// The fields a template can use, for Settings to list.
    static let templateFields = ["{reference}", "{title}", "{url}", "{labels}", "{body}", "{note}", "{number}", "{repo}"]

    static var template: String {
        let saved = UserDefaults.standard.string(forKey: templateKey) ?? ""
        return saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTemplate : saved
    }

    static func prompt(for issue: Issue, note: String = "", localRepo: String? = nil, template: String? = nil) -> String {
        let reference = localRepo?.lowercased() == issue.repo.lowercased() ? "#\(issue.number)" : "\(issue.repo)#\(issue.number)"
        var body = (issue.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The prompt travels in an environment variable: keep it sane.
        if body.count > 20000 { body = String(body.prefix(20000)) + "\n[…]" }
        let values: [String: String] = [
            "{reference}": reference, "{title}": issue.title, "{url}": issue.url,
            "{labels}": issue.labels.isEmpty ? "" : "Labels: " + issue.labels.joined(separator: ", "),
            "{body}": body, "{note}": note.isEmpty ? "" : "Note: " + note,
            "{number}": String(issue.number), "{repo}": issue.repo
        ]
        var text = template ?? Self.template
        // The body last: braces inside it stay as they are.
        for (field, value) in values where field != "{body}" {
            text = text.replacingOccurrences(of: field, with: value)
        }
        text = text.replacingOccurrences(of: "{body}", with: body)
        // Empty fields leave no gaps.
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "123-fix-login-redirect": the number, then the title's first words.
    static func branchName(for issue: Issue) -> String {
        var name = "\(issue.number)"
        for word in BranchNamer.slug(issue.title).split(separator: "-").prefix(6) {
            guard name.count + word.count + 1 <= 50 else { break }
            name += "-" + word
        }
        return name == "\(issue.number)" ? name + "-issue" : name
    }

    private static func issue(from json: [String: Any], repo: String?) -> Issue? {
        guard let number = json["number"] as? Int, let title = json["title"] as? String else { return nil }
        let url = json["url"] as? String ?? ""
        let labels = (json["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return Issue(
            repo: repo ?? IssueRef.parse(url)?.repo ?? "",
            number: number, title: title, url: url,
            state: json["state"] as? String ?? "OPEN", labels: labels,
            body: json["body"] as? String
        )
    }

    private static func failure(_ error: String) -> Lookup {
        let text = error.lowercased()
        if text.contains("could not resolve to a repository") { return .unavailable(L("GitHub doesn't know this repository.")) }
        if text.contains("could not resolve to an issue") || text.contains("not found") { return .notFound }
        if text.contains("gh auth login") || text.contains("authentication") { return .unavailable(L("gh is not signed in.")) }
        return .unavailable(L("GitHub didn't answer."))
    }

    // MARK: Cache

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var issues: [String: (Date, Issue)] = [:]
        private var lists: [String: (Date, [Issue], Bool)] = [:]
        private var slugs: [String: String?] = [:]
        /// Long enough for one ⌘N panel and the next; short enough that a
        /// new issue shows up soon.
        private let lifetime: TimeInterval = 300

        func issue(_ key: String) -> Issue? {
            lock.withLock { issues[key].flatMap { -$0.0.timeIntervalSinceNow < lifetime ? $0.1 : nil } }
        }

        func store(_ issue: Issue, key: String) {
            lock.withLock { issues[key] = (Date(), issue) }
        }

        func list(_ repo: String) -> ([Issue], Bool)? {
            lock.withLock { lists[repo].flatMap { -$0.0.timeIntervalSinceNow < lifetime ? ($0.1, $0.2) : nil } }
        }

        func store(_ list: ([Issue], Bool), repo: String) {
            lock.withLock { lists[repo] = (Date(), list.0, list.1) }
        }

        func slug(_ directory: String) -> String?? {
            lock.withLock { slugs[directory] }
        }

        func store(slug: String?, for directory: String) {
            lock.withLock { slugs[directory] = .some(slug) }
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0" ... "9").contains(self) }
}

extension String {
    /// The capture groups of the first match of `pattern`, nil without one.
    func groups(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
