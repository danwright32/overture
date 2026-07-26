import Testing
import Foundation
@testable import Overture

// #1498: the sweep suspends on a checked continuation while Dan answers, and a checked continuation is
// unforgiving in both directions. A second resume traps and crashes the app; a missing one leaves the run
// suspended forever, which on screen is the takeover modal spinning on a scout that can never finish. Both
// are reachable from an alert, so the exactly-once guarantee is tested here rather than trusted.
@MainActor
@Suite("The scout's read prompt answers exactly once (#1498)")
struct ScoutReadAskTests {

    @Test func anAnswerReachesTheSweep() {
        var answered: ScoutReadBudget.Choice? = nil
        let ask = ScoutReadAsk(pending: 47) { answered = $0 }

        ask.reply(.all)

        #expect(answered == .all)
    }

    // A button and a dismissal can both fire. The second must not reach the continuation, because a
    // checked continuation resumed twice traps.
    @Test func asecondAnswerNeverReachesTheSweep() {
        var answers: [ScoutReadBudget.Choice] = []
        let ask = ScoutReadAsk(pending: 47) { answers.append($0) }

        ask.reply(.firstBatch)
        ask.reply(.all)
        ask.replyIfUnanswered()

        #expect(answers == [.firstBatch])
    }

    // THE failure path: the alert goes away without a button. Doing nothing here is what hangs the run, so
    // the dismissal is a real answer, and it is the one that spends nothing.
    @Test func aDismissalStillAnswersAndItSpendsNothing() {
        var answered: ScoutReadBudget.Choice? = nil
        let ask = ScoutReadAsk(pending: 47) { answered = $0 }

        ask.replyIfUnanswered()

        #expect(answered == ScoutReadBudget.Choice.none)
        #expect(ScoutReadBudget.pagesToRead([1, 2, 3], choice: .none).isEmpty)
    }

    // The view clears its state on this, so an answered question cannot leave an alert on screen over a
    // decision the sweep has already acted on.
    @Test func anAskStopsWaitingOnceItIsAnswered() {
        let ask = ScoutReadAsk(pending: 47) { _ in }

        #expect(ask.isWaiting)
        ask.reply(.all)
        #expect(ask.isWaiting == false)
    }
}
