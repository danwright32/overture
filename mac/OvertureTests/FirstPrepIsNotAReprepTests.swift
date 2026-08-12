import Testing
import Foundation

// #2548. Dan, walking the review queue on 2026-08-11, on a show he had prepped by hand: "we should hide
// re-prep if it was a manual prep or rename it since it would be the first prep."
//
// The card said "Written by you" and the action row beside it said "Re-prep". No Prep run had ever served
// that show, so there was nothing to re-do, and the word said there was.
//
// Renamed, not hidden. Hiding takes away "Find contacts only", which is the most useful thing on a
// hand-prepped card: Dan typed one address himself and a run could find the others. The two redrafting
// choices already confirm before replacing his words (#2007), so the machinery was right and only the
// wording was wrong.
@Suite("A first prep is not a re-prep (#2548)")
struct FirstPrepIsNotAReprepTests {
    // The state the issue is about: Dan wrote the first and only draft this show has ever had.
    // `manualPrepOffer` only offers the manual sheet on a show with no draft at all, and no run has
    // stamped `reprepLastServedAt`, so the two facts together mean exactly that.
    @Test func aHandPreppedShowNoRunHasServedReadsAsAFirstPrep() {
        #expect(ReprepRequest.isFirstPrep(writtenByDan: true, lastServedAt: nil))
        #expect(ReprepRequest.verb(writtenByDan: true, lastServedAt: nil) == "Prep")
        #expect(ReprepRequest.gerund(writtenByDan: true, lastServedAt: nil) == "Prepping")
    }

    // A run HAS served it, so a second one really is a re-prep however the words got there. This is the
    // case `draftWrittenByDan` alone cannot tell apart: Dan hand-prepped, then pressed "Find contacts
    // only", which finds contacts without touching his text, so the flag stays true and a run has run.
    @Test func aHandPreppedShowARunHasAlreadyServedIsStillAReprep() {
        let served = Date(timeIntervalSince1970: 1_000_000)
        #expect(!ReprepRequest.isFirstPrep(writtenByDan: true, lastServedAt: served))
        #expect(ReprepRequest.verb(writtenByDan: true, lastServedAt: served) == "Re-prep")
        #expect(ReprepRequest.gerund(writtenByDan: true, lastServedAt: served) == "Re-prepping")
    }

    // The ordinary card, which is the overwhelming majority: a run wrote the draft, so the word is
    // unchanged. A rename that reached this case would relabel the whole queue.
    @Test func anAiDraftedShowStillSaysReprep() {
        #expect(!ReprepRequest.isFirstPrep(writtenByDan: false, lastServedAt: nil))
        #expect(ReprepRequest.verb(writtenByDan: false, lastServedAt: nil) == "Re-prep")
        #expect(ReprepRequest.verb(writtenByDan: false, lastServedAt: Date()) == "Re-prep")
    }

    // Every surface that says the word says it through the one rule, so they cannot disagree on one card.
    // The badge, the menu, the confirm's title and its button all read from `verb`.
    @Test func everySurfaceSpellsItTheSameWayOnOneShow() {
        for (byDan, served) in [(true, nil as Date?), (false, nil), (true, Date()), (false, Date())] {
            let verb = ReprepRequest.verb(writtenByDan: byDan, lastServedAt: served)
            #expect(ReprepRequest.menuLabel(writtenByDan: byDan, lastServedAt: served) == verb)
            #expect(ReprepRequest.confirmTitle(writtenByDan: byDan, lastServedAt: served)
                    == "\(verb) this show?")
            #expect(ReprepRequest.queuedBadge(writtenByDan: byDan, lastServedAt: served)
                    == "\(verb) queued")
        }
    }

    // The acknowledgement Dan reads after pressing it says the same word as the control he pressed.
    @Test func theAcknowledgementUsesTheSameWordAsTheControl() {
        #expect(ActionAck.reprepStarted(mode: .contactsOnly, draftGranted: false, org: "Aurora Strings",
                                        isFirstPrep: true)
                == "Prepping Aurora Strings to find new contacts")
        #expect(ActionAck.reprepStarted(mode: .draftOnly, draftGranted: true, org: "Aurora Strings",
                                        isFirstPrep: true)
                == "Prepping Aurora Strings to redraft")
        #expect(ActionAck.reprepStarted(mode: .contactsOnly, draftGranted: false, org: "Aurora Strings",
                                        isFirstPrep: false)
                == "Re-prepping Aurora Strings to find new contacts")
    }

    // Built is not wired (L3). Each surface has to actually ask the rule, or the rule is a sentence the
    // app never says.
    @Test func theCardActuallyAsksTheRule() {
        let draft = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(!draft.isEmpty)
        // No surface may hard-code the word any more: a literal is exactly how the badge and the menu came
        // to disagree with the card beside them.
        #expect(!draft.contains("Menu(\"Re-prep\")"), "the menu still hard-codes Re-prep")
        #expect(!draft.contains("Text(\"Re-prep queued\")"), "the badge still hard-codes Re-prep queued")
        #expect(!draft.contains(".alert(\"Re-prep this show?\""), "the confirm still hard-codes Re-prep")
        #expect(draft.contains("ReprepRequest.menuLabel"), "the menu does not ask the rule")
        #expect(draft.contains("ReprepRequest.queuedBadge"), "the badge does not ask the rule")
        #expect(draft.contains("ReprepRequest.confirmTitle"), "the confirm does not ask the rule")
    }
}
