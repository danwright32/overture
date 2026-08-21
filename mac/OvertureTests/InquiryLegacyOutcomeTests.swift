import Testing
import Foundation
import SwiftData

// #2950: `InquiryMutations.MarkAction.outcome` turned a close-out reason into the legacy `Outcome` by
// COMPARING against one value (`ending == .theySaidNo ? .lostHard : .lostSoft`) rather than switching
// exhaustively, which is what every other reader of this vocabulary does (#2586).
//
// A comparison answers for cases nobody has considered. Every ending added later landed on the soft case
// with nothing going red and nobody asked: #2863's `theySaidPriceTooHigh` walked straight into it, and
// soft happened to be right, which is luck rather than a decision (L113).
//
// The switch is now exhaustive, so adding any case to `ShowOutcome` breaks the build here. These tests
// are the other half, the one the compiler cannot judge: that the decision the break forces is right.
@Suite("An inquiry's close-out reason decides its legacy outcome per case (#2950)")
struct InquiryLegacyOutcomeTests {

    // The hard case means a refusal of the work itself, and it is the only one. Asserted over ALL cases
    // rather than over the few Dan meets, so an ending added later cannot quietly join it.
    @Test func onlyAFlatNoIsTheHardLoss() {
        for ending in ShowOutcome.allCases {
            let isHard = InquiryMutations.MarkAction.lost(ending).outcome == .lostHard
            #expect(isHard == (ending == .theySaidNo),
                    "\(ending) reads as a hard loss, which claims they refused the work")
        }
    }

    // Every ending Dan can actually pick on an inquiry row, and what each one must mean. The list comes
    // from `InquiryEnding.danCanChoose` rather than being written out again, so an ending added to the
    // show side arrives here rather than being missed.
    @Test func everyEndingDanCanPickLeavesTheDoorOpenUnlessTheyRefused() {
        for ending in InquiryEnding.danCanChoose {
            let expected: Outcome = ending == .theySaidNo ? .lostHard : .lostSoft
            #expect(InquiryMutations.MarkAction.lost(ending).outcome == expected,
                    "\(ending) does not land where the vocabulary says it should")
        }
    }

    // The case the comparison got wrong, and the reason it is worth naming rather than defaulting: an
    // ending that says the work BOOKED is not a loss, whatever it arrived wrapped in. Under the old
    // comparison this answered `.lostSoft` while `MarkAction.ending` answered `.booked`, so the two
    // fields written by the same call contradicted each other about the same fact.
    //
    // Unreachable today (the row's menu is `InquiryEnding.danCanChoose`, which excludes booked, and
    // Booked has its own control), which is exactly why nothing would have noticed.
    @Test func anEndingThatSaysBookedIsNotALoss() {
        let action = InquiryMutations.MarkAction.lost(.booked)

        #expect(action.outcome == .booked)
        #expect(action.ending == .booked, "the two halves of one call must not disagree about the fact")
    }

    // The never-pitched half cannot reach an inquiry close-out at all. Pinned so that a change letting
    // one through has to come past this rather than silently filing it as a soft loss.
    @Test func theNeverPitchedEndingsAreNotOnTheInquiryMenu() {
        for ending in ShowOutcome.neverPitched {
            #expect(!InquiryEnding.danCanChoose.contains(ending))
        }
    }
}
