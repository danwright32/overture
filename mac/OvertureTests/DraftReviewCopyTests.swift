import Testing
import Foundation
@testable import Overture

// #885: the draft review screen is where Overture's copy makes its most consequential promises. It says
// a draft WON'T send, that a contact is HELD BACK, that a send went out DESPITE a warning Dan confirmed.
// Every one of those was a string assembled inside the SwiftUI body, where no test could read it, on the
// screen immediately before an email reaches a stranger.
@Suite("Draft review copy (#885)")
struct DraftReviewCopyTests {

    // MARK: - "This draft won't send"

    // It names the actual finding rather than saying "there's a problem": the whole point is that Dan can
    // tell at a glance whether it is a bad link or a leftover placeholder, and fix it in one edit.
    @Test func theBlockMessageNamesTheFindingsThatAreHoldingTheSend() {
        let message = DraftCheck.blockMessage(blockers: [.foreignLink, .placeholder])

        #expect(message == "This draft won't send: \(DraftIssue.foreignLink.label) and \(DraftIssue.placeholder.label).")
    }

    // The fallback matters: a block with nothing to name would otherwise read "This draft won't send: ."
    // and tell Dan nothing at all about what to fix.
    @Test func aBlockWithNothingToNameStillSaysSomething() {
        #expect(DraftCheck.blockMessage(blockers: []) == "This draft won't send: a blocking issue.")
    }

    // MARK: - "Approved, but no email to send to" (#1311)
    //
    // SendService hard-blocks a send to a blank address, so an approved show with no emailable contact can
    // never go out. The greyed Send button never said why; this note explains the stall so Dan can act.
    // ONLY when there is genuinely no address: an email merely held by a review guard is a different,
    // already-explained case, and saying "no email" there would be untrue.
    @Test func anApprovedShowWithNoEmailAtAllExplainsWhyItCannotSend() {
        #expect(DraftReviewNotes.noSendableEmail(isApproved: true, hasPendingRecipient: false,
                                                 hasAnyEmailContact: false)
                    == "Approved, but no email to send to. Add a contact by hand.")
    }

    @Test func anApprovedShowWhoseEmailIsMerelyHeldSaysNothing() {
        // An address exists (held by a guard), so "no email to send to" would be untrue.
        #expect(DraftReviewNotes.noSendableEmail(isApproved: true, hasPendingRecipient: false,
                                                 hasAnyEmailContact: true) == nil)
    }

    @Test func aSendableOrUnapprovedShowSaysNothing() {
        #expect(DraftReviewNotes.noSendableEmail(isApproved: true, hasPendingRecipient: true,
                                                 hasAnyEmailContact: true) == nil)   // can send
        #expect(DraftReviewNotes.noSendableEmail(isApproved: false, hasPendingRecipient: false,
                                                 hasAnyEmailContact: false) == nil)  // not approved yet
    }

    // MARK: - Sending despite a warning
    //
    // #789's deliberate audit trail: an overridden warning TONES DOWN rather than disappearing, so there
    // is still a visible record that the send happened despite it. A sentence that vanished on override
    // would erase exactly the thing worth keeping.

    @Test func anOverriddenGreetingWarningStillLeavesATrail() {
        #expect(DraftReviewNotes.salutation(needsReview: true, overridden: true)
                    == "Sending despite the greeting warning you confirmed.")
    }

    @Test func anUnOverriddenGreetingWarningTellsDanToEditItFirst() {
        let note = DraftReviewNotes.salutation(needsReview: true, overridden: false)

        #expect(note?.contains("edit it before sending") == true)
    }

    @Test func aDraftWithNoGreetingProblemSaysNothingAtAll() {
        #expect(DraftReviewNotes.salutation(needsReview: false, overridden: false) == nil)
        #expect(DraftReviewNotes.salutation(needsReview: false, overridden: true) == nil)
    }

    @Test func anOverriddenLintWarningStillLeavesATrail() {
        #expect(DraftReviewNotes.lint(blocked: false, blockers: [.foreignLink])
                    == "Sending despite the draft warning you confirmed.")
    }

    @Test func aBlockedDraftNamesWhatIsBlockingIt() {
        #expect(DraftReviewNotes.lint(blocked: true, blockers: [.foreignLink])
                    == DraftCheck.blockMessage(blockers: [.foreignLink]))
    }

    @Test func aCleanDraftSaysNothingAtAll() {
        #expect(DraftReviewNotes.lint(blocked: false, blockers: []) == nil)
    }

    // MARK: - "N contacts held for a check"
    //
    // #792: "Sent" used to be the whole story, and a contact held back by a review guard is not sendable,
    // so a show read as fully done while a real person never received anything. This is the count that
    // says otherwise, and a count is a promise about rows.

    @Test func theHeldContactNotePluralizesAndCounts() {
        #expect(DraftReviewNotes.heldContacts(1) == "1 contact held for a check")
        #expect(DraftReviewNotes.heldContacts(3) == "3 contacts held for a check")
    }

    @Test func nothingHeldSaysNothing() {
        #expect(DraftReviewNotes.heldContacts(0) == nil)
    }

    // MARK: - The contact warnings
    //
    // Each names WHY a contact is suspect and states the consequence: blocked from sending. The
    // consequence is the load-bearing half, and it was a closure in a view body.

    @Test func eachContactWarningNamesTheContactAndTheConsequence() {
        #expect(DraftReviewNotes.venueSuspect(name: "Alice Tully Hall")
                    == "Alice Tully Hall may be the venue itself, not the act; blocked from sending.")
        #expect(DraftReviewNotes.pressSuspect(name: "Press Office")
                    == "Press Office may be a press/media contact, not the act; blocked from sending.")
        #expect(DraftReviewNotes.duplicateSuspect(name: "Ana Ruiz")
                    == "Ana Ruiz may already be pitched for a nearby show; blocked from sending.")
    }

    // MARK: - Re-prep

    @Test func aReprepConfirmSaysHowRecentlyItWasAlreadyDone() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let message = ReprepRequest.confirmMessage(lastServedAt: now.addingTimeInterval(-3_600), now: now)

        #expect(message.hasPrefix("This was re-prepped "))
        #expect(message.hasSuffix(". Redo it anyway?"))
    }

    // A prospect never re-prepped before has no time to state, and must not read "re-prepped ." with a
    // blank where the time should be.
    @Test func aFirstReprepJustAsks() {
        #expect(ReprepRequest.confirmMessage(lastServedAt: nil, now: Date()) == "Redo it anyway?")
    }

    // MARK: - Enum labels
    //
    // The codebase's convention is a `.label` on the enum (ConversationState, ArchiveStatus,
    // PerformanceStatus, DismissReason all have one). These two were switch statements inside views.

    @Test func everyProvenanceHasAWordDanRecognizes() {
        #expect(RecipientProvenance.act.label == "act")
        #expect(RecipientProvenance.performer.label == "performer")
        #expect(RecipientProvenance.presenter.label == "presenter")
        #expect(RecipientProvenance.manual.label == "added")
    }

    @Test func everyConfidenceHasALabel() {
        #expect(ContactConfidence.high.label == "high confidence")
        #expect(ContactConfidence.medium.label == "medium confidence")
        #expect(ContactConfidence.low.label == "low confidence")
    }

    // MARK: - #843: a blocking finding is not shown twice

    // Once a draft is approved and still blocked, the "This draft won't send: <finding>." gate by the Send
    // button names the finding, so the warning flag near the body would say the same thing again. In that
    // one case the flag steps aside; the gate keeps it.
    @Test func aBlockingFindingIsNotFlaggedNearTheBodyWhenTheGateAlreadyNamesIt() {
        #expect(DraftReviewNotes.showsBlockingFlagsNearBody(isApproved: true, lintBlocked: true) == false)
    }

    // Before approval there is no gate yet, so the flag is the only place the finding shows: it stays.
    @Test func aBlockingFindingStaysFlaggedBeforeApproval() {
        #expect(DraftReviewNotes.showsBlockingFlagsNearBody(isApproved: false, lintBlocked: true))
    }

    // After an override the gate no longer names the reason (it tones down to "Sending despite the draft
    // warning you confirmed."), so the specific finding must stay visible near the body.
    @Test func anOverriddenFindingStaysFlaggedNearTheBody() {
        #expect(DraftReviewNotes.showsBlockingFlagsNearBody(isApproved: true, lintBlocked: false))
    }

    // The guard and its wiring are two claims (#887): the rule only holds on screen if the view gates the
    // flags on it. Cut the wire and the finding is shown twice again with the unit tests still green.
    @Test func theViewGatesTheFlagsOnThatRule() {
        let view = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(view.contains("DraftReviewNotes.showsBlockingFlagsNearBody(isApproved: isApproved"))
    }
}
