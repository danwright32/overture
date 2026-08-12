import Testing
import Foundation
import SwiftData

// #1828: which action rows offer Re-prep, and what happens when the run it would start cannot run.
//
// The decision lives here rather than inside DraftReviewView's branches because a rule written as a
// SwiftUI `if` is untestable, and this one had already gone wrong in the branch that needs it most: a show
// with no address at all draws the form-pitch row, where "find contacts only" is the single highest-value
// action available, and that was the one card it could not be asked for. Every branch offers it now; the
// only thing that withholds it is a state where the run genuinely cannot happen.
@Suite("Where Re-prep is offered (#1828)")
struct ReprepOfferTests {

    private func item(status: ReviewStatus = .drafted,
                      formPitch: FormPitch.State = .unavailable,
                      conflict: Bool = false) -> QueueItem {
        var i = QueueItem(id: "k", groupName: "Aurora Strings", discipline: "music", venue: "The Room",
                          performanceDate: "2026-09-11", sourceListingURL: nil, websiteURL: nil,
                          priorRelationship: "none", production: "unknown", profile: "neutral",
                          coverage: "unknown", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: status)
        i.formPitch = formPitch
        i.hasUnclearedConflict = conflict
        i.draftBody = "a draft"
        return i
    }

    // The case in the issue. A show with no email renders the form-pitch row, and Re-prep belongs there.
    @Test func aFormPitchCardOffersReprep() {
        let ready = FormPitch.State.ready(recipientId: "r1", formURL: "https://venue.example/contact")
        #expect(QueueModel.reprepOffer(for: item(formPitch: ready)) == .shown)
    }

    // The ordinary drafted and approved cards keep offering it, unchanged.
    @Test func anOrdinaryDraftedOrApprovedCardOffersReprep() {
        #expect(QueueModel.reprepOffer(for: item(status: .drafted)) == .shown)
        #expect(QueueModel.reprepOffer(for: item(status: .approved)) == .shown)
    }

    // Dan's call, 2026-07-30: offered even here. A form pitch waiting on his answer is still a show whose
    // contacts he may want researched, and taking the control away mid-flow means noticing later that the
    // one card asking him a question is also the one card that cannot be re-prepped. Answering the
    // question is unaffected: both answers stay exactly where they were.
    @Test func aFormPitchAwaitingHisAnswerStillOffersReprep() {
        let waiting = FormPitch.State.awaitingConfirmation(recipientId: "r1",
                                                           formURL: "https://venue.example/contact",
                                                           startedAt: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(QueueModel.reprepOffer(for: item(formPitch: waiting)) == .shown)
    }

    // Unchanged from #367: re-prep is never offered on a show already emailed or given up on.
    @Test func aSentOrDismissedShowNeverOffersReprep() {
        #expect(QueueModel.reprepOffer(for: item(status: .contacted)) == .hidden)
        #expect(QueueModel.reprepOffer(for: item(status: .dismissed)) == .hidden)
    }

    // The trap this issue's own scope note found. `PrepQueueBuilder.needsPrep` refuses a show with an
    // uncleared clash BEFORE it consults the re-prep flags, so a run launched here finds no eligible item
    // and does nothing while the acknowledgement says work started. The offer has to say so instead.
    @Test func aShowOnABlockedNightSaysNothingWillRun() {
        let offer = QueueModel.reprepOffer(for: item(conflict: true))
        guard case let .blocked(reason) = offer else {
            Issue.record("expected a blocked offer, got \(offer)")
            return
        }
        #expect(!reason.isEmpty)
    }
}

// The other half: the offer can be right on screen while the action still confirms work that cannot
// happen. #1679 is this repo's proof that a rule and its enforcement are two claims.
@MainActor
@Suite("Re-prep refuses a run that cannot happen (#1828)")
struct ReprepBlockedActionTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ ctx: ModelContext, conflict: Bool) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-09-11",
                                          venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "The Room", performanceDate: "2026-09-11", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .drafted)
        p.draftBody = "Hi"
        if conflict { p.setScoutConflict("2026-09-11|booked") }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // Acknowledging a run that provably will not run is the fail-silent shape CLAUDE.md names: the flag is
    // set, a run launches, the queue builder refuses the item, and Dan is told his contacts are being found.
    @Test func aClashedShowLaunchesNothingAndSaysWhy() async throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, conflict: true)
        #expect(p.hasUnclearedConflict)   // the precondition the whole test rests on
        let feedback = ActionFeedback()
        let counter = ReprepLaunches()

        await ProspectMutations.reprep(QueueItem(p), mode: .contactsOnly, prospects: [p], context: ctx,
                                       feedback: feedback,
                                       startPrep: { _, _, _ in counter.launches += 1 })

        #expect(counter.launches == 0)
        #expect(p.reprepContactsRequested == false)   // no flag left behind to ride a later run silently
        #expect(feedback.message?.isEmpty == false)
        // #2548: neither spelling of the started message, so this cannot pass merely because the naming
        // rule chose the other word.
        for isFirstPrep in [true, false] {
            #expect(feedback.message != ActionAck.reprepStarted(mode: .contactsOnly, draftGranted: false,
                                                                org: "Aurora Strings",
                                                                isFirstPrep: isFirstPrep))
        }
    }

    // The same action on a show with no clash is untouched: this is a refusal of the impossible case only.
    @Test func aShowWithNoClashStillLaunches() async throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, conflict: false)
        let feedback = ActionFeedback()
        let counter = ReprepLaunches()

        await ProspectMutations.reprep(QueueItem(p), mode: .contactsOnly, prospects: [p], context: ctx,
                                       feedback: feedback,
                                       startPrep: { _, _, _ in counter.launches += 1 })

        #expect(counter.launches == 1)
        #expect(p.reprepContactsRequested)
    }

    @MainActor private final class ReprepLaunches { var launches = 0 }
}

// #1828 was a branch that forgot a control, so the guard has to be about the BRANCHES, not one of them.
// A rule and its wiring are two claims (#1679), and view code is where this one can silently regress: the
// next action branch someone adds either routes through the shared decision or quietly ships without
// Re-prep again, and no behavioural test can see the difference.
@Suite("Every action branch asks the same question about Re-prep (#1828)")
struct ReprepControlWiringTests {
    @Test func theViewDrawsReprepThroughTheSharedDecisionAndNowhereElse() {
        let view = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(view.contains("QueueModel.reprepOffer(for: item)"))
        // The old shape: an eligibility test written inline per branch. Its absence is the guard, since
        // that is exactly how one branch came to disagree with the other two.
        #expect(!view.contains("if item.isReprepEligible { reprepMenu }"))
    }

    // The action refuses what the card says it will refuse, so a caller that reaches the mutation another
    // way (a keyboard path, a future surface) cannot start a run the queue builder will decline.
    @Test func theActionEnforcesTheBlockedStateItself() {
        let mutations = SourceGuardHelper.source("Overture/UI/ProspectMutations.swift")
        #expect(mutations.contains("ActionAck.reprepBlockedByClash"))
    }
}
