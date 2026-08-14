import Testing
import Foundation

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

    // MARK: - "No email to send to" (#1311)
    //
    // SendService hard-blocks a send to a blank address, so a show with no emailable contact can never go
    // out. The greyed button never said why; this note explains the stall so Dan can act. ONLY when there
    // is genuinely no address: an email merely held by a review guard is a different, already-explained
    // case, and saying "no email" there would be untrue.
    //
    // #2050: it no longer waits for an approval, because approving is no longer a step of its own. The
    // button Dan presses is greyed by this while the show is still a draft, so the reason has to be
    // readable there or it is never read at all.
    @Test func aShowWithNoEmailAtAllExplainsWhyItCannotSend() {
        #expect(DraftReviewNotes.noSendableEmail(hasPendingRecipient: false, hasAnyEmailContact: false)
                    == "No email to send to. Add a contact by hand, by address or by link.")
    }

    @Test func aShowWhoseEmailIsMerelyHeldSaysNothing() {
        // An address exists (held by a guard), so "no email to send to" would be untrue.
        #expect(DraftReviewNotes.noSendableEmail(hasPendingRecipient: false, hasAnyEmailContact: true) == nil)
    }

    @Test func aSendableShowSaysNothing() {
        #expect(DraftReviewNotes.noSendableEmail(hasPendingRecipient: true, hasAnyEmailContact: true) == nil)
    }

    // MARK: - Sending despite a warning
    //
    // #789's deliberate audit trail: an overridden warning TONES DOWN rather than disappearing, so there
    // is still a visible record that the send happened despite it. A sentence that vanished on override
    // would erase exactly the thing worth keeping.

    // #2545: the greeting now lives in the body, so the two ways it can be wrong are that it is absent
    // and that it names one person on an email several people receive. Each gets its OWN sentence,
    // because they need opposite fixes: one is "write a greeting", the other is "take the name out".
    @Test func amissingGreetingSaysSoAndNamesTheFix() {
        let note = DraftReviewNotes.greeting(missing: true, misaddressed: false, audience: 1,
                                             overridden: false)

        #expect(note == "This draft won't send: it doesn't open with a greeting. Edit it to add one.")
    }

    @Test func agreetingThatNamesOnePersonOnASharedEmailSaysHowManyItReaches() {
        let note = DraftReviewNotes.greeting(missing: false, misaddressed: true, audience: 3,
                                             overridden: false)

        #expect(note == "This draft won't send: the greeting names one person but this email goes to 3. "
                + "Open it \"Hello,\" instead.")
    }

    @Test func anOverriddenGreetingWarningStillLeavesATrail() {
        #expect(DraftReviewNotes.greeting(missing: true, misaddressed: false, audience: 1,
                                          overridden: true)
                    == "Sending despite the greeting warning you confirmed.")
    }

    @Test func aDraftWithNoGreetingProblemSaysNothingAtAll() {
        #expect(DraftReviewNotes.greeting(missing: false, misaddressed: false, audience: 1,
                                          overridden: false) == nil)
        #expect(DraftReviewNotes.greeting(missing: false, misaddressed: false, audience: 1,
                                          overridden: true) == nil)
    }

    // L64/#718: the two-step confirm repeats WHAT is wrong before asking him to send anyway, so the
    // confirm is never a bare "are you sure" about a fact he has already scrolled past.
    @Test func thegreetingOverrideConfirmRepeatsWhatIsWrong() {
        let confirm = DraftReviewNotes.greetingOverrideConfirm(missing: true, misaddressed: false,
                                                               audience: 1)

        #expect(confirm == "This draft won't send: it doesn't open with a greeting. Edit it to add one. "
                + "Confirm you've checked it and it's fine to send as-is.")
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

    // While a draft is blocked, the "This draft won't send: <finding>." gate by the button names the
    // finding, so the warning flag near the body would say the same thing again. The flag steps aside; the
    // gate keeps it.
    //
    // #2050: the gate no longer waits for an approval to appear, because one button now carries the draft
    // from written to sent, so the question this asks is only whether the draft is blocked.
    @Test func aBlockingFindingIsNotFlaggedNearTheBodyWhenTheGateAlreadyNamesIt() {
        #expect(DraftReviewNotes.showsBlockingFlagsNearBody(lintBlocked: true) == false)
    }

    // After an override the gate no longer names the reason (it tones down to "Sending despite the draft
    // warning you confirmed."), so the specific finding must stay visible near the body.
    @Test func anOverriddenFindingStaysFlaggedNearTheBody() {
        #expect(DraftReviewNotes.showsBlockingFlagsNearBody(lintBlocked: false))
    }

    // The guard and its wiring are two claims (#887): the rule only holds on screen if the view gates the
    // flags on it. Cut the wire and the finding is shown twice again with the unit tests still green.
    @Test func theViewGatesTheFlagsOnThatRule() {
        let view = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(view.contains("DraftReviewNotes.showsBlockingFlagsNearBody(lintBlocked: item.draftLintBlocked)"))
    }
}
