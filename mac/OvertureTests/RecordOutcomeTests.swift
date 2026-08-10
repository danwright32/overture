import Testing
import Foundation
import SwiftData

// #2395, phase 2 of docs/plans/2026-08-09-one-outcome-vocabulary.md: every menu that ends a show writes
// through ONE mutation, so the dismiss menu, the close-out menu on the reached-out row, the full card's
// "Mark..." menu and Follow-ups' "Not this one" cannot each record the ending slightly differently.
//
// The guard this adds beyond the menus themselves is the point: a menu offering only what is possible is
// a promise about a screen, and the write path has to keep that promise even when a caller gets it wrong,
// because an impossible ending recorded once is indistinguishable afterwards from one Dan chose.
@MainActor
@Suite("Recording a show's outcome (#2395)")
struct RecordOutcomeTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, key: String = "k",
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Orchestra of St Luke's", discipline: "music",
                         venue: "V", performanceDate: "2026-11-18", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        ctx.insert(p)
        return p
    }

    private func pitched(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = show(ctx, key: key, status: .contacted)
        p.sentAt = Date()
        let r = Recipient(id: "a@b.com", email: "a@b.com", provenance: .manual)
        r.sendState = .sent
        r.sentAt = Date()
        r.prospect = p
        ctx.insert(r)
        return p
    }

    // MARK: the never-pitched half

    // A show nothing was sent to leaves the queue when it ends, which is what dismissing means, and the
    // exit has to be dated or the drop-off can be counted but never placed in a year (#16).
    @Test func aNeverPitchedEndingDismissesTheShowAndDatesTheExit() throws {
        let ctx = try context()
        let p = show(ctx)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .hadPaidWork, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(ok)
        #expect(p.showOutcome == .hadPaidWork)
        #expect(p.status == .dismissed)
        #expect(p.dismissedAt != nil)
    }

    // MARK: the pitched half

    // A pitch that ended is NOT a dismissal. It went out, it got an answer or failed to, and it leaves the
    // reached-out stage because it now carries an ending, not because it was cut from the queue. Marking it
    // dismissed would file a real pitch among the shows Dan never sent to.
    @Test func aPitchedEndingDoesNotDismissTheShow() throws {
        let ctx = try context()
        let p = pitched(ctx)

        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNotNow, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())

        #expect(p.showOutcome == .theySaidNotNow)
        #expect(p.status == .contacted)
        #expect(p.dismissedAt == nil)
    }

    // A booking Dan records by hand has to say it was his call, or the next Downbeat reconcile claims the
    // same show and silently moves it from the manual half of the booking split to the automatic one.
    @Test func aBookingIsRecordedAsDansOwnCall() throws {
        let ctx = try context()
        let p = pitched(ctx)

        _ = ProspectMutations.recordOutcome(QueueItem(p), .booked, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())

        #expect(p.showOutcome == .booked)
        #expect(p.outcome == .booked)
        #expect(p.outcomeSourceRaw == OutcomeSource.manual.rawValue)
    }

    // MARK: no impossible ending, enforced where it is written

    // The menus offer only the half that is possible, and this is the same promise kept one layer down. A
    // never-pitched reason on a show Dan already emailed would claim he never sent it.
    @Test func aNeverPitchedEndingIsRefusedOnAShowThatWasPitched() throws {
        let ctx = try context()
        let p = pitched(ctx)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .dateConflict, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(!ok)
        #expect(p.showOutcome == nil)
    }

    @Test func aPitchedEndingIsRefusedOnAShowNothingWasSentTo() throws {
        let ctx = try context()
        let p = show(ctx)

        let ok = ProspectMutations.recordOutcome(QueueItem(p), .neverHeardBack, prospects: [p],
                                                 context: ctx, feedback: ActionFeedback())

        #expect(!ok)
        #expect(p.showOutcome == nil)
    }

    // Overture's own two are not decisions, so no menu offers them and no hand can record them. `wentBy`
    // in particular is a fact about the calendar and must never read as a judgement Dan made.
    @Test func overturesOwnTwoCannotBeRecordedByHand() throws {
        let ctx = try context()
        for (i, outcome) in [ShowOutcome.wentBy, .tooFar].enumerated() {
            let p = show(ctx, key: "k\(i)")
            let ok = ProspectMutations.recordOutcome(QueueItem(p), outcome, prospects: [p],
                                                     context: ctx, feedback: ActionFeedback())
            #expect(!ok)
            #expect(p.showOutcome == nil)
        }
    }

    // A refusal has to SAY so. Silently doing nothing on a control Dan pressed is the worst of the three
    // outcomes: the row stays as it was and he has no way to tell that from a write that landed.
    @Test func arefusalTellsDanRatherThanFailingQuietly() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let feedback = ActionFeedback()

        _ = ProspectMutations.recordOutcome(QueueItem(p), .dateConflict, prospects: [p],
                                            context: ctx, feedback: feedback)

        #expect(feedback.message != nil)
    }

    // MARK: what Dan is told

    // The acknowledgment names the outcome back, because the row it was pressed on leaves the stage
    // immediately and a banner that only said "Saved" would be the sole evidence anything happened.
    @Test func theAcknowledgmentNamesTheOutcomeAndTheOrg() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let feedback = ActionFeedback()

        _ = ProspectMutations.recordOutcome(QueueItem(p), .turnedThemDown, prospects: [p],
                                            context: ctx, feedback: feedback)

        let said = feedback.message ?? ""
        #expect(said.contains("Orchestra of St Luke's"))
        #expect(said.lowercased().contains("turned them down"))
    }

    // Every value Dan can pick has to have words for the moment after he picks it. A missing line would
    // leave the one control whose row vanishes with nothing to show it worked.
    @Test func everyPickableOutcomeHasAnAcknowledgment() {
        for outcome in ShowOutcome.danCanChoose {
            let line = ShowOutcome.recordedLine(outcome, org: "Some Org")
            #expect(!line.isEmpty)
            #expect(line.contains("Some Org"))
        }
    }

    // No two acknowledgments may read the same, for the reason no two labels may: two endings described
    // in one sentence read as one ending.
    @Test func noTwoAcknowledgmentsReadTheSame() {
        let lines = ShowOutcome.danCanChoose.map { ShowOutcome.recordedLine($0, org: "Org") }
        #expect(Set(lines).count == lines.count)
    }

    // MARK: taking an ending back

    // The capability the old "In conversation" item actually provided. It was never an ending, it CLEARED
    // one, so replacing that menu with a list of endings has to keep a way back or a mis-pressed close-out
    // is unreachable from the card Dan is standing on.
    @Test func anEndingCanBeTakenBackAndTheShowReadsOpenAgain() throws {
        let ctx = try context()
        let p = pitched(ctx)
        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNo, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())
        #expect(p.showOutcome == .theySaidNo)

        let ok = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx,
                                                 feedback: ActionFeedback())

        #expect(ok)
        #expect(p.showOutcome == nil)
    }

    // #2396: recording an ending writes the SHOW and nothing else, so the contacts have nothing to clear.
    // Asserted on both sides of the round trip, because the earlier version of this wrote a copy onto every
    // contact and a reader that still expected one would fail silently rather than loudly.
    @Test func theContactsAreNeverTouchedByAnEnding() throws {
        let ctx = try context()
        let p = pitched(ctx)
        _ = ProspectMutations.recordOutcome(QueueItem(p), .theySaidNotNow, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())

        #expect(p.recipients.allSatisfy { $0.resolution == nil })
        #expect(p.performanceStatus == .lostDoorOpen, "read off the show's own ending")

        _ = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx,
                                            feedback: ActionFeedback())

        #expect(p.recipients.allSatisfy { $0.resolution == nil })
        #expect(p.performanceStatus == .active)
    }

    // Reopening a show that never ended does nothing and says nothing, rather than announcing an action
    // that did not happen.
    @Test func reopeningAShowWithNoEndingChangesNothing() throws {
        let ctx = try context()
        let p = pitched(ctx)
        let feedback = ActionFeedback()

        let ok = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx,
                                                 feedback: feedback)

        #expect(!ok)
        #expect(feedback.message == nil)
    }

    // It names the ending being removed. The card shows several facts at once, so "Reopened" alone would
    // not say which one went.
    @Test func theReopenAcknowledgmentNamesWhatWasRemoved() throws {
        let ctx = try context()
        let p = pitched(ctx)
        _ = ProspectMutations.recordOutcome(QueueItem(p), .neverHeardBack, prospects: [p],
                                            context: ctx, feedback: ActionFeedback())
        let feedback = ActionFeedback()

        _ = ProspectMutations.reopenOutcome(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        let said = feedback.message ?? ""
        #expect(said.contains("Orchestra of St Luke's"))
        #expect(said.contains("Never heard back"))
    }
}
