import Foundation

/// A task matches every word, across its title, repository, references and labels.
enum TaskSearch {
    static func matches(_ query: String, fields: [String]) -> Bool {
        let terms = normalize(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let text = normalize(fields.joined(separator: "\n"))
        return terms.allSatisfy { text.contains($0) }
    }

    static func fields(_ issue: Issue) -> [String] {
        [issue.title, issue.repo, "#\(issue.number)", issue.state] + issue.labels
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
