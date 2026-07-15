import Testing
import Foundation
import SwiftData
@testable import Overture

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

    // A single-night show: the banner offers a one-tap block, and taking it writes the day off (which the
    // conflict sweep then acts on) and confirms it.
    @Test func aSingleNightDismissOffersAOneTapBlockThatWritesTheDayOff() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(p), .dateConflict,
                                           prospects: [p], context: ctx, feedback: feedback, offer: offer)

        #expect(p.status == .dismissed)
        #expect(p.dismissReasonRaw == "date_conflict")
        let action = try #require(feedback.action)          // the offer is present
        #expect(action.label.contains("Block"))
        #expect(DayOffEditing.rows(in: ctx).isEmpty)        // nothing blocked until he taps

        action.perform()

        let rows = DayOffEditing.rows(in: ctx)
        #expect(rows.count == 1)
        #expect(rows.first?.startDate == "2026-11-18")
        #expect(rows.first?.endDate == "2026-11-18")
    }

    // A multi-night run: the banner action opens the picker (a pending request) pre-filled with the whole
    // run, rather than blocking anything outright, so Dan chooses the days.
    @Test func aRunDismissRaisesAPickerRequestForTheWholeRun() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18", runEnd: "2026-11-20")
        let feedback = ActionFeedback()
        let offer = DayOffOfferRequest()

        ProspectMutations.dismissForReason(QueueItem(p), .dayDoesntWork,
                                           prospects: [p], context: ctx, feedback: feedback, offer: offer)

        let action = try #require(feedback.action)
        #expect(offer.pending == nil)                       // nothing raised until he taps
        action.perform()

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

        ProspectMutations.dismissForReason(QueueItem(p), .notInterested,
                                           prospects: [p], context: ctx, feedback: feedback, offer: offer)

        #expect(p.status == .dismissed)
        #expect(feedback.action == nil)
        #expect(offer.pending == nil)
    }
}
