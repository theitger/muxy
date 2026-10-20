import Foundation

struct LandingReceipt: Codable, Equatable {
    var root: String
    var branch: String
    var pr: Int
    var goal: Landing.Goal
    var step: Landing.Step
    var since: Date
    var started: Date
    var asks: Int
    var quorumSince: Date?
    var provenHead: String?
    var reviewAttempts: Int?
    var requiresInspection: Bool?
    var autoMerges: Bool?
    var id: String { WorkItem.key(root: root, branch: branch) }

    enum Recovery: Equatable { case observe, check, inspect }

    func recovery(accepted: Bool, agentWorking: Bool) -> Recovery {
        switch step {
        case .reviewing: return quorumSince == nil ? .inspect : .observe
        case .merging: return provenHead == nil ? .inspect : .observe
        case .waitingForAgent: return agentWorking ? .observe : .inspect
        case .waitingForLanding: return .observe
        case .preparing, .proving, .pushing: return accepted ? .check : .inspect
        case .reviewed, .landed, .failed: return .observe
        }
    }

}

/// Records intent before an external operation; resumption reconciles that
/// intent with Git, quorum and GitHub instead of replaying commands blindly.
@MainActor
final class LandingJournal: ObservableObject {
    @Published private(set) var receipts: [String: LandingReceipt] = [:]
    @Published private(set) var problem: String?
    private let file: URL
    /// Decode failures protect the existing journal. Write failures may be
    /// transient and should be retried when the next transition is saved.
    private var canSave = true

    var persistenceBlocked: Bool { !canSave }

    init(file: URL = URL(fileURLWithPath: StateDirectory.path + "/landing.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { receipts = try JSONDecoder().decode([String: LandingReceipt].self, from: Data(contentsOf: file)) }
        catch {
            canSave = false
            problem = L("Landing could not be restored: %@", error.localizedDescription)
        }
    }

    @discardableResult
    func put(_ receipt: LandingReceipt) -> Bool {
        guard canSave else { return false }
        var next = receipts
        next[receipt.id] = receipt
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            receipts = next
            problem = nil
            return true
        } catch {
            problem = L("Landing could not be saved: %@", error.localizedDescription)
            return false
        }
    }
}
