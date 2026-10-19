import Foundation

/// A checkout's files as they were at a moment of an agent's work: before
/// a turn began and after it ended. Kept as commits under
/// `refs/muxy/turns/<checkout>/`, so they cost nothing but git objects,
/// survive restarts and never show up in `git log` or a push.
struct Checkpoint: Identifiable, Hashable {
    enum Moment: String {
        /// The turn is about to start: what the agent began from.
        case before
        /// The turn ended.
        case after
    }

    var ref: String
    var commit: String
    var date: Date
    var moment: Moment
    /// What the agent said it did (after), or the task it got (before).
    var label: String

    var id: String { ref }
}

/// Snapshots per turn, the diff of each, and putting the files back.
/// Blocking; call off the main thread.
enum Checkpoints {
    private static let git = WorkState.git
    static let namespace = "refs/muxy/turns/"
    /// Older checkpoints of a checkout go: plenty to step back through.
    static let keep = 60

    /// The refs folder for one checkout: its folder name plus a short hash
    /// of its path, so two checkouts called "app" stay apart.
    static func prefix(for checkout: String) -> String {
        let name = (checkout as NSString).lastPathComponent
        let slug = String(name.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-"
        })
        var hash: UInt32 = 2_166_136_261
        for byte in checkout.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return namespace + slug + "-" + String(hash, radix: 16) + "/"
    }

    /// Records the checkout's files when they differ from the last
    /// checkpoint's. nil: nothing new (or not a git checkout).
    @discardableResult
    static func record(_ moment: Checkpoint.Moment, label: String, in checkout: String) -> Checkpoint? {
        let subject = label.split(separator: "\n").first.map(String.init) ?? ""
        let message = "muxy \(moment.rawValue)\n\n\(subject.prefix(300))"
        guard let snapshot = WorkState.snapshot(of: checkout, message: message) else { return nil }
        let existing = list(in: checkout)
        if let last = existing.first,
           Shell.run(git, ["rev-parse", last.commit + "^{tree}"], in: checkout) == snapshot.tree {
            return nil
        }
        // A commit of its own even when the files equal HEAD: the label
        // and the moment travel in its message.
        let commit = snapshot.commit == snapshot.head
            ? Shell.execute(git, ["commit-tree", snapshot.tree, "-p", snapshot.head, "-m", message],
                            in: checkout, timeout: 30, environment: WorkState.identity).output
            : snapshot.commit
        guard !commit.isEmpty else { return nil }
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
        let ref = prefix(for: checkout) + stamp + "-" + moment.rawValue
        guard Shell.execute(git, ["update-ref", ref, commit], in: checkout).status == 0 else { return nil }
        prune(existing.dropFirst(keep - 1), in: checkout)
        return Checkpoint(ref: ref, commit: commit, date: Date(), moment: moment, label: subject)
    }

    /// Newest first.
    static func list(in checkout: String) -> [Checkpoint] {
        guard let output = Shell.run(git, [
            "for-each-ref", "--sort=-refname",
            "--format=%(refname)%09%(objectname)%09%(body)%00", prefix(for: checkout)
        ], in: checkout) else { return [] }
        return output.split(separator: "\0").compactMap { entry in
            let fields = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return nil }
            let ref = fields[0]
            let name = (ref as NSString).lastPathComponent
            let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2, let millis = Double(parts[0]),
                  let moment = Checkpoint.Moment(rawValue: parts[1]) else { return nil }
            return Checkpoint(
                ref: ref, commit: fields[1], date: Date(timeIntervalSince1970: millis / 1000),
                moment: moment, label: fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            )
        }
    }

    /// Puts the checkout's files back to the checkpoint's. Commits made
    /// since stay; what they changed shows as uncommitted changes. The
    /// files as they were right before are kept as a checkpoint of their
    /// own, so this can be undone. Staging is cleared (back to HEAD).
    static func restore(_ checkpoint: Checkpoint, in checkout: String) -> Bool {
        // No going back without a way back: the files as they are must be
        // readable (recorded now, or equal to the last checkpoint).
        guard WorkState.snapshot(of: checkout) != nil else { return false }
        record(.after, label: L("Before going back"), in: checkout)
        // Everything into the index first, so read-tree also removes files
        // that are new since the checkpoint.
        guard Shell.execute(git, ["add", "-A", "--", "."], in: checkout, timeout: 120).status == 0,
              Shell.execute(git, ["read-tree", "-u", "--reset", checkpoint.commit + "^{tree}"],
                            in: checkout, timeout: 120).status == 0
        else { return false }
        return Shell.execute(git, ["reset", "--quiet", "--mixed"], in: checkout, timeout: 60).status == 0
    }

    /// Removes a checkout's checkpoints (its worktree is gone).
    static func forget(_ checkout: String, root: String) {
        guard let output = Shell.run(git, ["for-each-ref", "--format=%(refname)", prefix(for: checkout)], in: root)
        else { return }
        for ref in output.split(separator: "\n") {
            _ = Shell.execute(git, ["update-ref", "-d", String(ref)], in: root)
        }
    }

    private static func prune(_ old: ArraySlice<Checkpoint>, in checkout: String) {
        for checkpoint in old {
            _ = Shell.execute(git, ["update-ref", "-d", checkpoint.ref], in: checkout)
        }
    }
}
