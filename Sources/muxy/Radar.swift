import Foundation

/// Where parallel work will collide, found while it is still cheap to fix:
/// every session's files (uncommitted ones included) merged in git's
/// object store with every other session's of the same repository and
/// with the branch they will land on. Nothing is checked out; a check
/// takes milliseconds.
///
/// Two kinds, never shown alike: another session changes the same lines
/// as this one (it collides), or this branch would conflict with the one
/// it lands on (it is behind and needs that merged in).
struct Collision: Equatable, Hashable {
    /// The other session's checkout, or the base branch ("origin/main").
    var other: String
    /// True when `other` is the branch it lands on.
    var withBase: Bool
    var files: [String]

    /// The base without its remote: "origin/development" → "development".
    var baseName: String {
        other.hasPrefix("origin/") ? String(other.dropFirst("origin/".count)) : other
    }
}

@MainActor
final class Radar: ObservableObject {
    static let shared = Radar()

    @Published private(set) var byCheckout: [String: [Collision]] = [:]
    /// It has looked at least once: no collisions means none, not "not yet".
    private(set) var scanned = false
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var scanning = false
    /// merge-tree answers by commit pair: the same files are never merged twice.
    private let memo = Memo()

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        timer.tolerance = 15
        self.timer = timer
        poke(after: 5)
    }

    func collisions(for checkout: String?) -> [Collision] {
        checkout.flatMap { byCheckout[$0] } ?? []
    }

    /// What a collision is called everywhere it shows.
    func describe(_ collision: Collision) -> String {
        collision.withBase ? L("conflicts with %@", collision.baseName) : L("collides with %@", title(of: collision.other))
    }

    /// Something changed (a turn ended): look again shortly.
    func poke(after delay: TimeInterval = 4) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func scan() {
        guard !scanning else { return }
        var byRoot: [String: Set<String>] = [:]
        for workspace in Store.shared.workspaces {
            let context = workspace.context
            // Work on its way to a PR: a branch of its own, not landed or given up.
            guard let root = context.root, let checkout = context.checkout, let branch = context.branch,
                  !WorkLedger.isBase(branch), context.prState == .open
            else { continue }
            byRoot[root, default: []].insert(checkout)
        }
        guard !byRoot.isEmpty else {
            if !byCheckout.isEmpty { byCheckout = [:] }
            return
        }
        scanning = true
        let memo = memo
        Task.detached(priority: .utility) {
            var collected: [String: [Collision]] = [:]
            for (root, checkouts) in byRoot {
                guard let found = Self.scan(root: root, checkouts: Array(checkouts).sorted(), memo: memo) else {
                    await MainActor.run { self.scanning = false }
                    return
                }
                collected.merge(found) { $1 }
            }
            let found = collected
            await MainActor.run {
                self.scanning = false
                self.scanned = true
                let before = self.byCheckout
                if found != before { self.byCheckout = found }
                self.announce(before: before, after: found)
            }
        }
    }

    /// nil means git could not complete the scan. Callers keep the previous
    /// result in that case: an unavailable checkout is not evidence that its
    /// collisions went away.
    nonisolated static func scan(root: String, checkouts: [String], memo: Memo) -> [String: [Collision]]? {
        let start = Launcher.startPoint(in: root, recipe: WorktreeRecipe.load(root: root))
        guard let base = Shell.run(WorkState.git, ["rev-parse", "--verify", start], in: root) else { return nil }
        var snapshots: [(checkout: String, commit: String, own: Set<String>)] = []
        for checkout in checkouts {
            guard let snapshot = WorkState.snapshot(of: checkout),
                  let own = memo.own(snapshot.commit, base: base, in: root)
            else { return nil }
            // Nothing of its own (a fresh session, or one that only took the
            // base in): nothing to collide.
            if own.isEmpty { continue }
            snapshots.append((checkout, snapshot.commit, own))
        }
        var found: [String: [Collision]] = [:]
        for item in snapshots {
            guard let files = memo.conflicts(item.commit, base, in: root) else { return nil }
            if !files.isEmpty {
                found[item.checkout, default: []].append(Collision(other: start, withBase: true, files: files))
            }
        }
        for i in snapshots.indices {
            for j in snapshots.indices where j > i {
                let a = snapshots[i], b = snapshots[j]
                // Only lines both changed themselves: a session that merged the
                // base in carries the base's files, and an older session's
                // conflict with those is its conflict with the base, said there.
                let shared = a.own.intersection(b.own)
                guard !shared.isEmpty else { continue }
                guard let files = memo.conflicts(a.commit, b.commit, in: root)?.filter(shared.contains) else { return nil }
                guard !files.isEmpty else { continue }
                found[a.checkout, default: []].append(Collision(other: b.checkout, withBase: false, files: files))
                found[b.checkout, default: []].append(Collision(other: a.checkout, withBase: false, files: files))
            }
        }
        return found
    }

    /// A collision that wasn't there before lights up both sessions.
    private func announce(before: [String: [Collision]], after: [String: [Collision]]) {
        for (checkout, list) in after {
            let new = list.filter { collision in !(before[checkout] ?? []).contains { $0.other == collision.other } }
            guard let first = new.first,
                  let workspace = Store.shared.workspaces.first(where: { $0.context.checkout == checkout }),
                  let session = workspace.primary else { continue }
            session.markAttentionIfBackground(reason: describe(first))
        }
    }

    /// The other session's name, for a collision with it.
    func title(of checkout: String) -> String {
        Store.shared.workspaces.first { $0.context.checkout == checkout }?.title ?? (checkout as NSString).lastPathComponent
    }

    final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: [String]] = [:]
        private var owned: [String: Set<String>] = [:]

        /// The files a commit changed since it left the base (since the
        /// last merge of the base, when it took one in).
        func own(_ commit: String, base: String, in root: String) -> Set<String>? {
            let key = commit + base
            if let known = lock.withLock({ owned[key] }) { return known }
            guard let fork = Shell.run(WorkState.git, ["merge-base", commit, base], in: root) else { return nil }
            let files: Set<String>
            if fork == commit {
                files = []
            } else {
                let changed = Shell.execute(WorkState.git, ["diff", "--name-only", "-z", fork, commit], in: root, timeout: 60)
                guard changed.status == 0 else { return nil }
                files = Set(changed.output.split(separator: "\0").map(String.init))
            }
            lock.withLock {
                if owned.count > 2000 { owned.removeAll() }
                owned[key] = files
            }
            return files
        }

        func conflicts(_ a: String, _ b: String, in root: String) -> [String]? {
            let key = a < b ? a + b : b + a
            if let known = lock.withLock({ answers[key] }) { return known }
            guard let files = WorkState.conflicts(between: a, and: b, in: root) else { return nil }
            lock.withLock {
                if answers.count > 2000 { answers.removeAll() }
                answers[key] = files
            }
            return files
        }
    }
}
