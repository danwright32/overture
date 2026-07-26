import Foundation

// #1498: the pending "read all of them, or 20 now?" question, and the one-shot answer behind it.
//
// The sweep asks this by suspending on a checked continuation, which is unforgiving in both directions: a
// SECOND resume traps and crashes, and a MISSING one leaves the run suspended forever, which on screen is
// the takeover modal spinning on a scout that will never finish. Both are reachable from an alert. A button
// can fire alongside a dismissal, and a dismissal on its own fires no button at all.
//
// So the resume lives here, where it can be made exactly-once, rather than in three button closures that
// each have to remember. Whatever happens to the alert, the sweep gets exactly one answer.
@MainActor
final class ScoutReadAsk: Identifiable {
    let id = UUID()
    let pending: Int
    private var pendingAnswer: ((ScoutReadBudget.Choice) -> Void)?

    init(pending: Int, answer: @escaping (ScoutReadBudget.Choice) -> Void) {
        self.pending = pending
        self.pendingAnswer = answer
    }

    // True until the sweep has been answered. The view clears its state on this, so a stale alert cannot
    // linger over a question that is already settled.
    var isWaiting: Bool { pendingAnswer != nil }

    func reply(_ choice: ScoutReadBudget.Choice) {
        pendingAnswer?(choice)
        pendingAnswer = nil
    }

    // The dismissal, called wherever the alert can go away without a button: it answers `.none`, which
    // spends nothing and loses nothing. Deliberately NOT a no-op, because doing nothing here is the one
    // outcome that hangs the run.
    func replyIfUnanswered() {
        reply(.none)
    }
}
