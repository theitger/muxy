import Foundation

/// A log workspace follows a PR even when its checkout is on the default branch.
struct QuorumReference: Codable, Equatable {
    var root: String
    var number: Int
    var repo: String?
    var log: String?
    var logOnly: Bool?

    static func fromLogTitle(_ title: String, root: String, repo: String?) -> QuorumReference? {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("tail "), title.contains("/quorum/"),
              let range = title.range(of: #"(?:babysit|review)-(\d+)-"#, options: .regularExpression) else { return nil }
        let parts = title[range].split(separator: "-")
        guard parts.count >= 2, let number = Int(parts[1]), number > 0 else { return nil }
        return QuorumReference(root: root, number: number, repo: repo)
    }
}
