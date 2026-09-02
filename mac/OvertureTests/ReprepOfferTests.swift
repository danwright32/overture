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
                          performanceDate: "2026-09-11", sourceListingURL: nil,
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

    // #3369 DELETED `aShowOnABlockedNightSaysNothingWillRun`. It asserted the offer was BLOCKED with a
    // reason on a clashed night, because `needsPrep` refused such a show before reading the re-prep flags.
    // The gate is gone (Dan, 2026-09-01), so it is deleted rather than adjusted (L252).

    // What replaces it: the offer is made, and the clash reaches Dan at the launch confirm.
    @Test func aShowOnABlockedNightIsOfferedTheRun() {
        #expect(QueueModel.reprepOffer(for: item(conflict: true)) == .shown)
    }
}

// #3369 REPLACED the suite that stood here, `ReprepBlockedActionTests`. Its subject was the refusal under
// the offer: a clashed show launching nothing and saying why. Nothing refuses on a clash any more, so the
// refusal cases are deleted (L252) and what remains is the half that never depended on them, which is that
// the action really does launch and really does record its request.
@MainActor
@Suite("Re-prep launches the run it says it will (#1828, #3369)")
struct ReprepActionTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ ctx: ModelContext, conflict: Bool) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-09-11",
                                          venue: "The Room")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "The Room", performanceDate: "2026-09-11", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .drafted)
        p.draftBody = "Hi"
        if conflict { p.setScoutConflict("2026-09-11|booked") }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // #3369: a clash does not stop the run, and the request is recorded rather than dropped. The clash
    // itself is untouched by launching: prepping is not an answer to it, and the send gate still reads it.
    @Test func aClashedShowLaunchesAndKeepsItsClash() async throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx, conflict: true)
        #expect(p.hasUnclearedConflict)   // the precondition the whole test rests on
        let feedback = ActionFeedback()
        let counter = ReprepLaunches()

        await ProspectMutations.reprep(QueueItem(p), mode: .contactsOnly, prospects: [p], context: ctx,
                                       feedback: feedback,
                                       startPrep: { _, _, _ in counter.launches += 1 })

        #expect(counter.launches == 1)
        #expect(p.reprepContactsRequested)
        #expect(p.hasUnclearedConflict, "launching a run is not an answer to the clash")
    }

    // The same action on a show with no clash, so the test above cannot pass by the clash being ignored
    // everywhere including where it still matters.
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

    // #3369 DELETED `theActionEnforcesTheBlockedStateItself`, which asserted the mutation named the
    // refusal sentence. There is no refusal, so the guard has nothing to hold. The claim above it, that
    // every branch draws Re-prep through one shared decision, is untouched and is the one #1828 was about.
}
