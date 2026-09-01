import Testing
import Foundation

// #3358 Phase 2. `checkMissedItHelp` says an earlier check "never got an answer for it", which was true
// of the ONE population that could reach this state when #1724 wrote it: a show the run never reached.
//
// #3451 added a second population to the same state. A run that DID NOT FINISH is no longer believed
// about a show it answered with nothing, so that show now routes here too. For it the sentence is
// false: the run did write an answer, and what is wrong with it is that the run died before it could be
// trusted, not that no answer arrived.
//
// A message may claim only what its check actually measured (L11). The two causes are not given
// separate sentences, and that is a decision rather than an omission: the remedy is identical (re-check
// it), nothing Dan does differs between them, and a second badge state would divide his attention by a
// distinction he cannot act on. What changes is that the one sentence stops asserting the half it
// cannot know.
//
// Dan's decision 1, 2026-08-31: ship the draft and correct it live.
@Suite("The missed-check sentence is true of both ways a check can leave a show unsettled (#3358)")
struct TheMissedCheckSentenceIsTrueOfBothCausesTests {

    // The false claim, pinned so it cannot come back. "never got an answer" is exactly the half that is
    // untrue of a show a dying run answered.
    @Test func itDoesNotClaimNoAnswerArrived() {
        #expect(!ReachabilityCopy.checkMissedItHelp.lowercased().contains("never got an answer"),
                "the sentence still claims no answer arrived, which is false of a show a dying run answered")
    }

    // What it must still say, because these are the two things Dan acts on and #2621 established them:
    // the show is still unchecked, and nothing re-checks it on its own.
    @Test func itStillSaysWhatItCostsAndThatNothingFixesItAlone() {
        let help = ReachabilityCopy.checkMissedItHelp.lowercased()
        #expect(help.contains("unchecked"), "it no longer says the show is still unchecked")
        #expect(help.contains("on its own"), "it no longer says nothing re-checks it by itself")
    }

    // It must not become a guess about WHY, which the row cannot support: nothing on it records whether
    // the run died or never arrived, and #1724's comment says so.
    @Test func itDoesNotGuessWhyTheRunCameHomeShort() {
        let help = ReachabilityCopy.checkMissedItHelp.lowercased()
        for guess in ["crashed", "timed out", "rate limit", "killed", "failed"] {
            #expect(!help.contains(guess), "the sentence guesses at a cause the row does not record: \(guess)")
        }
    }

    // The badge is unchanged and stays distinct from a finding, which is #1724's whole point: "No email
    // found" is a conclusion about the show and this is the absence of one.
    @Test func theBadgeStillSaysWhatHappenedRatherThanWhatWasFound() {
        #expect(ReachabilityCopy.checkMissedItBadge != ReachabilityCopy.noEmailFoundBadge)
        #expect(!ReachabilityCopy.checkMissedItBadge.lowercased().contains("found"))
    }
}
