import Testing
import Foundation
import SwiftData
@testable import Overture

// #901, Dan's decision (2026-07-13): a show on a day he cannot work still appears, flagged, with the
// reason named, and is not draftable until he clears it. He decides, not the app.
//
// Until now the scout DROPPED it: `.skip(.blocked)`, counted, unnamed, gone. That was defensible when
// the blocked set was a bare list of dates with no reason attached, and indefensible once he asked to
// see them. It also hid the guard's own emptiness: a drop that never happened looks exactly like a drop
// that could never have happened.
@MainActor
@Suite("A blocked day flags the show, it does not drop it (#901)")
struct ConflictSurfacedTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func event(_ title: String, date: String = "2099-09-19", end: String? = nil) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: "Stern Auditorium / Perelman Stage",
                       performanceDate: date,
                       sourceUrl: "https://www.carnegiehall.org/Calendar/\(title)-\(date)")
    }

    private func vacation(_ start: String, _ end: String, note: String? = "Vacation") -> BlockedCalendar {
        BlockedCalendar.build(bookings: [], exportedBlockedDates: [],
                              daysOff: [DayOffRange(startDate: start, endDate: end, note: note)])
    }

    private func booked(_ shoot: String, _ date: String) -> BlockedCalendar {
        BlockedCalendar.build(
            bookings: [OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "A Client",
                                       shootName: shoot, startDate: date, endDate: date,
                                       venueId: nil, venueName: "Somewhere")],
            exportedBlockedDates: [], daysOff: [])
    }

    @discardableResult
    private func run(_ events: [ExtractedEvent], blocked: BlockedCalendar,
                     in ctx: ModelContext) -> ScoutService.Outcome {
        let existing = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        return ScoutService.apply(events: events, clients: [],
                                  history: LocalHistory.forMatching(existing: existing),
                                  blocked: blocked, today: ScoutTestClock.beforeAllFixtures,
                                  sourceIds: [WatchedSource.carnegieId], into: ctx)
    }

    private func stored(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // MARK: - It is kept, and it is flagged

    @Test func aShowOnADayOffIsImportedAndCarriesTheReason() throws {
        let ctx = try context()
        let outcome = run([event("Vienna Philharmonic", date: "2099-09-19")],
                          blocked: vacation("2099-09-14", "2099-09-22"), in: ctx)

        #expect(outcome.inserted == 1)                 // it is HERE, not dropped
        #expect(outcome.skipped == 0)

        let p = try #require(stored(ctx).first)
        #expect(p.hasUnclearedConflict)
        #expect(p.conflictNote == "You blocked Sep 19 (Vacation).")
    }

    @Test func aShowOnABookedShootNamesTheShoot() throws {
        let ctx = try context()
        run([event("Vienna Philharmonic", date: "2099-09-19")],
            blocked: booked("Nguyen Recital", "2099-09-19"), in: ctx)

        let p = try #require(stored(ctx).first)
        #expect(p.conflictNote == "You're already shooting Nguyen Recital on Sep 19.")
    }

    @Test func aShowOnAFreeDayCarriesNoConflict() throws {
        let ctx = try context()
        run([event("Vienna Philharmonic", date: "2099-09-19")],
            blocked: vacation("2099-10-01", "2099-10-05"), in: ctx)

        let p = try #require(stored(ctx).first)
        #expect(p.hasUnclearedConflict == false)
        #expect(p.conflictNote == nil)
    }

    // MARK: - The suppression report keeps its meaning (#901's second trap)

    // Every line in that report means "somebody asked you to stop". A date clash is not a refusal, and
    // now that it is not even a skip, it must still stay out of it.
    @Test func aBlockedDayIsNotARefusalAndIsNotReportedAsOne() throws {
        let ctx = try context()
        let outcome = run([event("Vienna Philharmonic", date: "2099-09-19")],
                          blocked: vacation("2099-09-19", "2099-09-19"), in: ctx)

        #expect(outcome.suppressedOrgs.isEmpty)
    }

    // MARK: - The run trap, end to end

    // The old check tested the opening night alone. A run Dan can start but cannot finish is a run he
    // must not be pitched without being told.
    @Test func aRunCollidingOnlyOnALaterNightIsFlagged() throws {
        let ctx = try context()
        // Two nights of one run, at one venue: the scout collapses them, and the collision is on night 2.
        run([event("Takács Quartet", date: "2099-09-19"), event("Takács Quartet", date: "2099-09-20")],
            blocked: booked("Nguyen Recital", "2099-09-20"), in: ctx)

        let p = try #require(stored(ctx).first)
        #expect(p.runEndDate == "2099-09-20")          // it really was collapsed into one run
        #expect(p.hasUnclearedConflict)
        #expect(p.conflictNote == "You're already shooting Nguyen Recital on Sep 20.")
    }

    // MARK: - Dan's decision survives, and a CHANGED conflict does not inherit it (#718's pattern)

    @Test func hisClearanceSurvivesTheNextScout() throws {
        let ctx = try context()
        let cal = vacation("2099-09-19", "2099-09-19")
        run([event("Vienna Philharmonic")], blocked: cal, in: ctx)
        let p = try #require(stored(ctx).first)

        p.clearConflict(); try? ctx.save()
        #expect(p.hasUnclearedConflict == false)

        run([event("Vienna Philharmonic")], blocked: cal, in: ctx)   // same clash, next day's scout
        #expect(p.hasUnclearedConflict == false)                     // still his decision, not re-raised
    }

    // He waved through "you're on vacation". He has NOT waved through "you are shooting a wedding".
    @Test func aDifferentConflictOnTheSameDayBlocksAgain() throws {
        let ctx = try context()
        run([event("Vienna Philharmonic")], blocked: vacation("2099-09-19", "2099-09-19"), in: ctx)
        let p = try #require(stored(ctx).first)
        p.clearConflict(); try? ctx.save()

        run([event("Vienna Philharmonic")], blocked: booked("Nguyen Recital", "2099-09-19"), in: ctx)

        #expect(p.hasUnclearedConflict)                              // a new fact, and he has not seen it
        #expect(p.conflictNote == "You're already shooting Nguyen Recital on Sep 19.")
    }

    // The vacation was cancelled. The show is simply free again: no flag, and nothing for him to clear.
    @Test func removingTheBlockUnflagsTheShow() throws {
        let ctx = try context()
        run([event("Vienna Philharmonic")], blocked: vacation("2099-09-19", "2099-09-19"), in: ctx)
        let p = try #require(stored(ctx).first)
        #expect(p.hasUnclearedConflict)

        run([event("Vienna Philharmonic")], blocked: .empty, in: ctx)

        #expect(p.hasUnclearedConflict == false)
        #expect(p.conflictNote == nil)
    }

    // MARK: - Not draftable until he clears it

    @Test func aConflictedShowIsNotPreppedUntilHeClearsIt() throws {
        let ctx = try context()
        run([event("Vienna Philharmonic")], blocked: vacation("2099-09-19", "2099-09-19"), in: ctx)
        let p = try #require(stored(ctx).first)
        p.status = .queued                                          // Dan keeps it anyway

        #expect(PrepQueueBuilder.needsPrepEligible(p) == false)     // but no money is spent drafting it

        p.clearConflict(); try? ctx.save()
        #expect(PrepQueueBuilder.needsPrepEligible(p) == true)      // now it is ordinary work
    }

    // The failure path that a prep-only gate would miss: the draft already exists, and the conflict
    // turns up afterwards (he books a shoot, or blocks the week, AFTER approving the email).
    @Test func aConflictArrivingAfterTheDraftStopsTheSend() throws {
        let ctx = try context()
        run([event("Vienna Philharmonic")], blocked: .empty, in: ctx)
        let p = try #require(stored(ctx).first)
        p.status = .approved
        p.draftSubject = "A subject"
        p.draftBody = "A body that says nothing wrong."
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        p.setRecipients([r])
        try? ctx.save()
        #expect(SendService.nextPendingRecipient(for: p) != nil)    // it was ready to go

        run([event("Vienna Philharmonic")], blocked: vacation("2099-09-19", "2099-09-19"), in: ctx)

        #expect(r.isSendablePending == false)
        #expect(SendService.nextPendingRecipient(for: p) == nil)    // and nothing can send it

        p.clearConflict(); try? ctx.save()
        #expect(SendService.nextPendingRecipient(for: p) != nil)    // his call, and it goes
    }

    // MARK: - Where it sits in the queue

    // Dan's call, REVISED after walking the build (2026-07-14): a conflicted show stays in its normal
    // date position, marked with a highly visible badge, and is NOT reordered. The first build sank it to
    // the bottom of the queue, and a single-show date sliding to the end read as the show being deleted,
    // which is the exact disappearance this whole feature exists to prevent. So the order is by date, flag
    // or no flag; the badge does the work of telling him, not the position.
    @Test func aConflictedShowKeepsItsDatePositionAndIsNotReordered() throws {
        let ctx = try context()
        // The conflicted show is the EARLIER date, so if anything sank it, it would land last.
        run([event("Vienna Philharmonic", date: "2099-09-19"), event("Takács Quartet", date: "2099-09-25")],
            blocked: vacation("2099-09-19", "2099-09-19"), in: ctx)

        // Fed in date order, the way the queue's own query hands them over (queueOrder preserves input
        // order for same-window shows; it does not sort). The point is that the conflicted show is NOT
        // pulled out of that order to the bottom.
        let items = stored(ctx).map(QueueItem.init)
            .sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }
        let ordered = QueueModel.queueOrder(items, today: "2099-08-01")

        #expect(ordered.count == 2)                                     // both present
        #expect(ordered.first?.groupName == "Vienna Philharmonic")      // the earlier date, conflicted, still first
        #expect(ordered.first?.hasUnclearedConflict == true)            // it kept its place, badge and all
        #expect(ordered.first?.conflictNote == "You blocked Sep 19 (Vacation).")
    }
}
