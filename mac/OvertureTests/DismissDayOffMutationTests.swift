import Testing
import Foundation
import SwiftData

// #924: dismissing a show for a calendar reason records the dismissal AND offers to block the date. The
// offer is on the banner (an action Dan taps), never automatic. This drives the mutation end to end with a
// real store so the single-tap block actually writes a DayOff, and the run path actually raises a picker
// request, rather than trusting a source read.
@MainActor
@Suite("Dismiss offers a day off (#924)")
struct DismissDayOffMutationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, on date: String, runEnd: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k-\(date)", groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium", performanceDate: date, sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.runEndDate = runEnd
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // A calendar-reason dismissal opens the centered picker (a pending request), pre-filled with the show's
    // date, rather than a missable banner. It commits nothing until Dan confirms in the picker: the reason
    // Dan wanted a modal here is that dismissing for a date reason almost always means he'll block it.
    @Test func aSingleNightCalendarDismissOpensThePickerForThatDay() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(p), .dateConflict,
                                           prospects: [p], context: ctx, feedback: feedback, offer: offer)

        #expect(p.status == .dismissed)
        #expect(p.showOutcomeRaw == "date_conflict")
        let pending = try #require(offer.pending)           // the centered picker is raised, not a banner
        #expect(pending.start == "2026-11-18")
        #expect(pending.end == "2026-11-18")
        #expect(feedback.action == nil)                     // no missable banner offer
        #expect(DayOffEditing.rows(in: ctx).isEmpty)        // nothing blocked until he confirms in the picker
    }

    // A multi-night run opens the same picker, pre-filled with the whole run, so Dan narrows it there.
    @Test func aRunDismissOpensThePickerForTheWholeRun() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18", runEnd: "2026-11-20")
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(p), .dateConflict,
                                           prospects: [p], context: ctx, feedback: feedback, offer: offer)

        let pending = try #require(offer.pending)
        #expect(pending.start == "2026-11-18")
        #expect(pending.end == "2026-11-20")
        #expect(DayOffEditing.rows(in: ctx).isEmpty)        // the picker has not committed anything
    }

    // A non-calendar reason records the dismissal and offers nothing.
    @Test func aNonCalendarDismissOffersNothing() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(p), .notAFit,
                                           prospects: [p], context: ctx, feedback: feedback, offer: offer)

        #expect(p.status == .dismissed)
        #expect(offer.pending == nil)
        #expect(feedback.action == nil)
    }

    // Dismissing a SECOND show on a date Dan already blocked must NOT pop the picker again: the show
    // already reads "unavailable" (it carries an uncleared conflict), so there is nothing to capture.
    @Test func dismissingAShowOnAnAlreadyBlockedDateDoesNotOffer() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        p.setScoutConflict("dayOff|2026-11-18|Vacation")   // its date is already blocked
        try ctx.save()
        #expect(p.hasUnclearedConflict)
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(p), .dateConflict,
                                           prospects: [p], context: ctx, feedback: feedback, offer: offer)

        #expect(p.status == .dismissed)     // still dismissed
        #expect(offer.pending == nil)       // but no picker: the date is already blocked
    }

    // #939: dismissing one venue's row for a calendar reason, when a same-production show at a DIFFERENT
    // venue nearby is also in the queue, widens the picker to cover both dates in one action.
    @Test func dismissingOneVenueOfATouringShowWidensThePickerToTheOtherVenuesDate() throws {
        let ctx = try context()
        let p1 = Prospect(naturalKey: "moca-25", groupName: "MOCA PERFORMS", discipline: "theater",
                          venue: "Museum of Chinese in America", performanceDate: "2026-07-25", sourceListingURL: nil,
                          websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .queued)
        let p2 = Prospect(naturalKey: "moca-24", groupName: "MOCA PERFORMS", discipline: "theater",
                          venue: "Open Door Senior Center", performanceDate: "2026-07-24", sourceListingURL: nil,
                          websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .queued)
        ctx.insert(p1); ctx.insert(p2); try ctx.save()
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(p1), .dateConflict,
                                           prospects: [p1, p2], context: ctx, feedback: feedback, offer: offer)

        let pending = try #require(offer.pending)
        #expect(pending.start == "2026-07-24")
        #expect(pending.end == "2026-07-25")
    }

    // The picker's confirm goes through blockDaysOff, the one writer, which adds the day off (the conflict
    // sweep then acts on it) and confirms it.
    @Test func blockDaysOffWritesTheDayOffAndConfirms() throws {
        let ctx = try context()
        let feedback = ActionFeedback()

        let ok = ProspectMutations.blockDaysOff(start: "2026-11-18", end: "2026-11-20",
                                                note: "Away", context: ctx, feedback: feedback)

        #expect(ok)
        let rows = DayOffEditing.rows(in: ctx)
        #expect(rows.count == 1)
        #expect(rows.first?.startDate == "2026-11-18")
        #expect(rows.first?.endDate == "2026-11-20")
        #expect(feedback.message?.contains("blocked") == true)
    }
}
