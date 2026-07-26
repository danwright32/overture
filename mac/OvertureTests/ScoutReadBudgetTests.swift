import Testing
import Foundation
@testable import Overture

// #1498: a scout Dan started no longer rations the FREE half of its work. The budget used to cap which
// sources a manual run fetched, and fetching costs nothing: only a page whose content actually changed is
// ever handed to the paid read. So a 62-source watchlist checked 20 sources a press and left the rest
// untouched, which is why Finding B's three sources looked stranded when they were merely three presses
// back. And spreading the same reads over three presses saves nothing, it just makes Dan press three times.
//
// The question moved to where the money is. Over the threshold the run stops and asks with the TRUE count,
// because by then it has fetched and hashed everything and knows exactly how many pages need reading.
@Suite("How many pages one scout may read before it asks (#1498)")
struct ScoutReadBudgetTests {

    // The ordinary press. Nothing to ask about, so nothing interrupts him.
    @Test func aRunInsideTheThresholdJustReads() {
        #expect(ScoutReadBudget.decide(pending: 1) == .readThemAll)
        #expect(ScoutReadBudget.decide(pending: 10) == .readThemAll)
    }

    // Exactly at the threshold is still not a question: the old budget read 20 without asking, and a
    // prompt that fires on the number Dan is used to would read as a new obstacle rather than a guard.
    @Test func exactlyTheThresholdIsNotAQuestion() {
        #expect(ScoutReadBudget.decide(pending: 20) == .readThemAll)
    }

    // One over, and he is asked. The count in the decision is the REAL number of pages, so the sentence he
    // reads cannot quote a different figure from the one the run would actually spend on.
    @Test func oneOverTheThresholdAsksWithTheRealCount() {
        #expect(ScoutReadBudget.decide(pending: 21) == .ask(pending: 21))
        #expect(ScoutReadBudget.decide(pending: 47) == .ask(pending: 47))
    }

    // Nothing changed: there is no run to ask about, and certainly no prompt.
    @Test func nothingPendingIsNeverAQuestion() {
        #expect(ScoutReadBudget.decide(pending: 0) == .readThemAll)
    }

    // MARK: what each answer actually reads

    // "Read all" reads the whole set, in the order it was given (the fairness order the sweep built).
    @Test func readingAllTakesEveryPendingPageInOrder() {
        let pending = Array(1...47)
        #expect(ScoutReadBudget.pagesToRead(pending, choice: .all) == pending)
    }

    // "Read 20 now" takes the FRONT of that order, never an arbitrary 20. The sweep hands them over
    // oldest-first by the manual fairness clock, so the ones that have waited longest go first and the
    // rest keep their older clock and are genuinely next press.
    @Test func readingOneBatchTakesTheFrontOfTheFairnessOrder() {
        let pending = Array(1...47)
        let read = ScoutReadBudget.pagesToRead(pending, choice: .firstBatch)

        #expect(read == Array(1...20))
        #expect(read.count == ScoutReadBudget.askAbove)
    }

    // THE failure path, and the reason a dismissed prompt is safe: backing out spends nothing at all.
    // Nothing is lost either, because a page Overture fetched but did not read keeps its unread flag and
    // its older clock, so the next press offers it again at the front.
    @Test func backingOutReadsNothing() {
        #expect(ScoutReadBudget.pagesToRead(Array(1...47), choice: .none).isEmpty)
    }

    // A batch answer on a set SMALLER than the batch reads what there is rather than trapping on the
    // prefix. Unreachable through the ask (it only fires above the threshold), but pagesToRead is the one
    // place the split is decided and it must not depend on its caller having checked first.
    @Test func aBatchLargerThanWhatIsPendingReadsWhatThereIs() {
        #expect(ScoutReadBudget.pagesToRead([1, 2, 3], choice: .firstBatch) == [1, 2, 3])
    }

    // MARK: the sentence Dan reads

    // The count is stated once and comes from the same number the decision carries, so the question and
    // the work can never quote different figures.
    @Test func theQuestionNamesTheRealCountAndWhatEachAnswerCosts() {
        let title = ScoutReadBudget.askTitle(pending: 47)
        let message = ScoutReadBudget.askMessage(pending: 47)

        #expect(title.contains("47"))
        #expect(message.contains("27"))          // what is left over if he reads one batch
        #expect(ScoutReadBudget.readAllTitle(pending: 47).contains("47"))
        #expect(ScoutReadBudget.readBatchTitle().contains("20"))
    }
}
