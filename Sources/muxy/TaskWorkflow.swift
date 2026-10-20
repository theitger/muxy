import Foundation

struct AutomationLimits: Codable, Equatable {
    var hours = 8
    var reviews = 2
    var repairs = 3

    var seconds: TimeInterval { TimeInterval(min(max(hours, 1), 48) * 3600) }
    var reviewAttempts: Int { min(max(reviews, 0), 10) }
    var repairAttempts: Int { min(max(repairs, 0), 10) }
}

struct TaskTarget: Equatable, Identifiable {
    var issue: Issue?
    var root: String?
    var branch: String?
    var title: String

    var id: String {
        if let issue { return "\(issue.repo.lowercased())#\(issue.number)" }
        return WorkItem.key(root: root ?? "", branch: branch ?? title)
    }

    init(issue: Issue) {
        self.issue = issue
        title = issue.title
    }

    @MainActor init(workspace: Workspace) {
        issue = workspace.sessions.compactMap(\.issue).first
        root = workspace.context.root
        branch = workspace.context.branch
        title = workspace.title
    }

    init(work: WorkItem) {
        issue = work.issue
        root = work.root
        branch = work.branch
        title = work.title
    }
}

struct TaskCriterion: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var checkedHead: String?
    var fromIssue: Bool?

    func checked(at head: String?) -> Bool { head != nil && checkedHead == head }
}

struct TaskFeedback: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
    var head: String?
    var screenshot: String?
}

struct TaskRecord: Codable, Equatable {
    var issueBody: String?
    var issueTitle: String?
    var customGoal: Bool?
    var ignoredIssueCriteria: [String]?
    var criteriaImported: Bool?
    var limits: AutomationLimits?
    var goal = ""
    var criteria: [TaskCriterion] = []
    var feedback: [TaskFeedback] = []
    var draft = ""
    var lastInspectedHead: String?
    var inspectedAt: Date?

    mutating func synchronize(_ issue: Issue, previousTitle: String) {
        if customGoal != true, goal.isEmpty || goal == (issueTitle ?? previousTitle) {
            goal = issue.title
        }
        // Older records imported checkboxes without tracking their origin.
        if criteriaImported == true {
            let previous = Set(Self.criteria(from: issueBody ?? "").map(\.text))
            for index in criteria.indices where criteria[index].fromIssue == nil {
                criteria[index].fromIssue = previous.contains(criteria[index].text)
            }
        }
        let imported = Dictionary(criteria.filter { $0.fromIssue == true }.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
        let local = criteria.filter { $0.fromIssue != true }
        let localTexts = Set(local.map(\.text))
        let ignored = Set(ignoredIssueCriteria ?? [])
        var seen = Set<String>()
        let current = Self.criteria(from: issue.body ?? "").filter {
            !localTexts.contains($0.text) && !ignored.contains($0.text) && seen.insert($0.text).inserted
        }.map { criterion -> TaskCriterion in
            var value = imported[criterion.text] ?? criterion
            value.fromIssue = true
            return value
        }
        criteria = current + local
        issueBody = issue.body
        issueTitle = issue.title
        criteriaImported = true
    }

    mutating func removeCriterion(_ criterion: TaskCriterion) {
        if criterion.fromIssue == true {
            ignoredIssueCriteria = Array(Set((ignoredIssueCriteria ?? []) + [criterion.text]))
        }
        criteria.removeAll { $0.id == criterion.id }
    }

    static func criteria(from body: String) -> [TaskCriterion] {
        body.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") else { return nil }
            let text = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : TaskCriterion(text: text)
        }
    }

    func satisfied(at head: String?) -> Bool { criteria.allSatisfy { $0.checked(at: head) } }
}

/// Human notes and receipts belong to the work, independently of a window.
@MainActor
final class TaskLedger: ObservableObject {
    static let shared = TaskLedger()
    @Published private(set) var records: [String: TaskRecord] = [:]
    @Published private(set) var problem: String?
    private let file: URL

    init(file: URL = URL(fileURLWithPath: StateDirectory.path + "/tasks.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { records = try JSONDecoder().decode([String: TaskRecord].self, from: Data(contentsOf: file)) }
        catch { problem = L("Task notes could not be loaded: %@", error.localizedDescription) }
    }

    func record(for target: TaskTarget) -> TaskRecord { records[target.id] ?? TaskRecord() }

    @discardableResult
    func update(_ id: String, _ change: (inout TaskRecord) -> Void) -> Bool {
        // Never overwrite a file we failed to decode.
        guard problem == nil else { return false }
        var next = records
        var record = next[id] ?? TaskRecord()
        change(&record)
        if records[id] == record { return true }
        next[id] = record
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            records = next
            return true
        } catch {
            problem = L("Task notes could not be saved: %@", error.localizedDescription)
            return false
        }
    }

    func instructions(for issue: Issue) -> String {
        let record = record(for: TaskTarget(issue: issue))
        var lines: [String] = []
        if !record.goal.isEmpty, record.goal != issue.title { lines += ["User's task goal:", record.goal] }
        if !record.criteria.isEmpty {
            lines += ["Acceptance criteria recorded by the user:"] + record.criteria.map { "- " + $0.text }
        }
        return lines.joined(separator: "\n")
    }

    func inspect(_ workspace: Workspace, head: String?) {
        guard let head else { return }
        update(TaskTarget(workspace: workspace).id) {
            $0.lastInspectedHead = head
            $0.inspectedAt = Date()
        }
    }
}

/// Pure dependency validation: removal, cycles and incomplete predecessors
/// cannot silently allow a dependent issue to start.
enum TaskDependencies {
    static func validate(id: String, dependencies: [String], graph: [String: [String]]) -> String? {
        if dependencies.contains(id) { return L("An issue cannot depend on itself.") }
        for dependency in dependencies {
            guard graph[dependency] != nil else { return L("The prerequisite is no longer in the queue.") }
            var pending = [dependency]
            var seen = Set<String>()
            while let current = pending.popLast() {
                if current == id { return L("These dependencies form a cycle.") }
                guard seen.insert(current).inserted else { continue }
                pending.append(contentsOf: graph[current] ?? [])
            }
        }
        return nil
    }

    static func waiting(_ dependencies: [String], merged: Set<String>) -> [String] {
        dependencies.filter { !merged.contains($0) }
    }
}

/// A dependent task must begin on a freshly fetched base, including any
/// prerequisite that just merged. Never reset a user's local checkout.
enum TaskBase {
    static func refresh(in root: String) -> String? {
        let start = Launcher.startPoint(in: root, recipe: WorktreeRecipe.load(root: root))
        guard start.hasPrefix("origin/") else {
            return L("Dependent tasks need a remote base in the worktree recipe.")
        }
        let branch = String(start.dropFirst("origin/".count))
        let result = Shell.execute(WorkState.git, ["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], in: root, timeout: 60)
        guard result.status == 0 else { return L("The latest base could not be fetched. The dependent task was not started.") }
        return nil
    }
}

/// Merge order is local to a repository; waiting requests keep their order.
enum MergeOrder {
    struct Entry {
        var id: String
        var root: String
        var started: Date
        var waiting: Bool
    }

    static func mayStart(_ candidate: Entry, among entries: [Entry]) -> Bool {
        !entries.contains { other in
            guard other.id != candidate.id, other.root == candidate.root else { return false }
            if !other.waiting { return true }
            return (other.started, other.id) < (candidate.started, candidate.id)
        }
    }
}
