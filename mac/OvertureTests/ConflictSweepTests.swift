import Testing
import Foundation
import SwiftData
@testable import Overture

// #901: blocking a week has to flag the shows in that week NOW, not on the next scout.
//
// The conflict is computed during a scout, which is right for a show arriving from a calendar. But the
// calendar Dan is judged against is the OTHER input, and he changes that one himself, by hand, in the
// Days off sheet. Without this, he blocks his vacation, looks at the queue, sees nothing flagged, and
// concludes it did not work. Meanwhile the shows he cannot shoot stay draftable until the next scout
// happens to run.
//
// The wiring is asserted here, not just the sweep: DayOffEditing.add and .remove are what Dan actually
// touches, so the test calls THOSE, and cutting the wire between them and the sweep has to turn this red.
@MainActor
@Suite("Blocking a day flags its shows at once (#901)")
struct ConflictSweepTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, on date: String, status: ReviewStatus = .queued,
                      runEnd: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: "key-\(date)", groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium / Perelman Stage", performanceDate: date,
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        p.runEndDate = runEnd
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // THE test. Dan blocks his vacation, and the show inside it is flagged before he looks away.
    @Test func addingADayOffFlagsAStoredShowImmediately() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        #expect(p.hasUnclearedConflict == false)

        DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation",
                          export: (bookings: [], blockedDates: []), into: ctx)

        #expect(p.hasUnclearedConflict)                               // no scout needed
        #expect(p.conflictNote == "You blocked Nov 18 (Vacation).")
        #expect(PrepQueueBuilder.needsPrepEligible(p) == false)       // and it is off the Prep work-list
    }

    // The other direction, which matters just as much: the trip is cancelled, and the shows he can now
    // shoot must stop being held back. A flag that only ever goes ON is a slow leak of dead leads.
    @Test func removingADayOffUnflagsItsShowsImmediately() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation",
                          export: (bookings: [], blockedDates: []), into: ctx)
        #expect(p.hasUnclearedConflict)

        let row = try #require(DayOffEditing.rows(in: ctx).first)
        DayOffEditing.remove(row, export: (bookings: [], blockedDates: []), in: ctx)

        #expect(p.hasUnclearedConflict == false)
        #expect(p.conflictNote == nil)
        #expect(PrepQueueBuilder.needsPrepEligible(p) == true)        // draftable again
    }

    // A run whose LATER night falls in the blocked week is caught by the sweep too, not just by the scout.
    @Test func theSweepJudgesTheWholeRunNotItsOpeningNight() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-12", runEnd: "2026-11-15")     // opens before the trip, closes inside it

        DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation",
                          export: (bookings: [], blockedDates: []), into: ctx)

        #expect(p.hasUnclearedConflict)
        #expect(p.conflictNote == "You blocked Nov 14 (Vacation).")   // the first night he would miss
    }

    // Dan's own decision is not undone by an unrelated edit. He waved this show through; blocking a
    // DIFFERENT week must not resurrect the flag on it.
    @Test func anUnrelatedEditDoesNotUndoAClearanceHeAlreadyMade() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation",
                          export: (bookings: [], blockedDates: []), into: ctx)
        p.clearConflict()                                              // "I can shoot this anyway"
        try ctx.save()

        DayOffEditing.add(start: "2026-12-01", end: "2026-12-03", note: "Family",
                          export: (bookings: [], blockedDates: []), into: ctx)

        #expect(p.hasUnclearedConflict == false)                      // still his call
    }

    // A booked shoot from Downbeat outranks the sweep's day-off reason on the same date, exactly as it
    // does during a scout: one calendar, one set of rules, whoever asks it.
    @Test func theSweepUsesTheSameCalendarTheScoutDoes() throws {
        let ctx = try context()
        let p = show(ctx, on: "2026-11-18")
        let booking = OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "A Client",
                                      shootName: "Nguyen Recital", startDate: "2026-11-18",
                                      endDate: "2026-11-18", venueId: nil, venueName: "V")

        DayOffEditing.add(start: "2026-11-14", end: "2026-11-22", note: "Vacation",
                          export: (bookings: [booking], blockedDates: []), into: ctx)

        #expect(p.conflictNote == "You're already shooting Nguyen Recital on Nov 18.")
    }
}
