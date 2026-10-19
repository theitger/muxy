import Foundation

/// Each checkout's checkpoints for the views: recorded when an agent
/// starts and ends a turn (see Checkpoints), listed newest first.
@MainActor
final class Turns: ObservableObject {
    static let shared = Turns()

    @Published private(set) var byCheckout: [String: [Checkpoint]] = [:]
    /// Checkouts being put back right now.
    @Published private(set) var restoring: Set<String> = []

    func checkpoints(for checkout: String?) -> [Checkpoint] {
        checkout.flatMap { byCheckout[$0] } ?? []
    }

    /// The agent got a prompt: what it starts from.
    func turnStarted(in session: TerminalSession) {
        guard let checkout = session.context.checkout else { return }
        record(.before, label: L("Before the turn"), in: checkout)
    }

    /// The agent ended its turn: what it came to, under its own words.
    func turnEnded(in checkout: String, summary: String?) {
        record(.after, label: summary.map { PlainText.shortened($0, to: 200) } ?? L("Turn ended"), in: checkout)
    }

    func refresh(_ checkout: String?) {
        guard let checkout else { return }
        Task.detached(priority: .utility) {
            let list = Checkpoints.list(in: checkout)
            await MainActor.run { self.byCheckout[checkout] = list }
        }
    }

    /// Puts the files back; calls back whether it worked.
    func restore(_ checkpoint: Checkpoint, in checkout: String, then: @escaping (Bool) -> Void) {
        guard !restoring.contains(checkout) else { return }
        restoring.insert(checkout)
        Task.detached(priority: .userInitiated) {
            let done = Checkpoints.restore(checkpoint, in: checkout)
            let list = Checkpoints.list(in: checkout)
            await MainActor.run {
                self.restoring.remove(checkout)
                self.byCheckout[checkout] = list
                then(done)
            }
        }
    }

    private func record(_ moment: Checkpoint.Moment, label: String, in checkout: String) {
        // "Before" races the agent's first edits: it goes first.
        Task.detached(priority: moment == .before ? .userInitiated : .utility) {
            Checkpoints.record(moment, label: label, in: checkout)
            let list = Checkpoints.list(in: checkout)
            await MainActor.run { self.byCheckout[checkout] = list }
        }
    }
}
