import Testing
import Foundation
import SwiftData

// #1421: the blocked calendar is built once for the app and kept current by the sweep, instead of being
// built inside two view bodies on every redraw.
//
// Two claims, asserted separately because they fail separately (#887: a guard and its wiring are two
// claims). The CACHE: reading the calendar costs no build. The WIRING: every change Dan makes reaches the
// cached calendar before the call that made it returns, so no surface can draw the calendar as it was.
@MainActor
@Suite("The app keeps one blocked calendar, current on every change (#1421)")
struct AvailabilitySnapshotTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, CancelledShoot.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let booking = OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "A Client",
                                          shootName: "Nguyen Recital", startDate: "2026-11-18",
                                          endDate: "2026-11-18", venueId: nil, venueName: "V")

    private var export: DayOffEditing.Export { (bookings: [booking], blockedDates: [], health: .ok) }

    // A counting loader, so "reading costs nothing" is a count rather than a feeling.
    private final class Loads { var count = 0 }

    @Test func readingTheCalendarBuildsNothing() throws {
        let ctx = try context()
        let loads = Loads()
        let snapshot = AvailabilitySnapshot(loadExport: { loads.count += 1; return self.export })
        snapshot.attach(to: ctx)
        defer { snapshot.detach() }
        #expect(loads.count == 1)
        #expect(snapshot.builds == 1)

        // What a hundred redraws of the toolbar and the sheet do.
        for _ in 0..<100 {
            _ = DaysOffAttention.reason(snapshot.calendar, feedStalled: false)
            _ = snapshot.bookings
        }

        #expect(loads.count == 1, "a read decoded the export; the render path is paying again")
        #expect(snapshot.builds == 1)
        #expect(snapshot.calendar.days.map(\.name) == ["Nguyen Recital"])   // and it holds the real thing
        #expect(snapshot.bookings.map(\.id) == ["b1"])
    }

    // THE wiring. Blocking a range from anywhere reaches the cached calendar before `add` returns, and it
    // arrives as the calendar the sweep judged against rather than a second read of the export.
    @Test func blockingADayReachesTheSnapshotBeforeTheCallReturns() throws {
        let ctx = try context()
        let loads = Loads()
        let snapshot = AvailabilitySnapshot(loadExport: { loads.count += 1; return self.export })
        snapshot.attach(to: ctx)
        defer { snapshot.detach() }

        DayOffEditing.add(start: "2026-11-20", end: "2026-11-21", note: "Away", export: export, into: ctx)

        #expect(snapshot.calendar.days.contains { $0.kind == .dayOff && $0.date == "2026-11-20" })
        #expect(snapshot.builds == 2)
        #expect(loads.count == 1, "the snapshot read the export again rather than taking the sweep's calendar")

        let row = try #require(DayOffEditing.rows(in: ctx).first)
        DayOffEditing.remove(row, export: export, in: ctx)
        #expect(!snapshot.calendar.days.contains { $0.kind == .dayOff })
    }

    // The sibling writers: cancelling and restoring a booked shoot change the calendar too, and reach it
    // the same way.
    @Test func cancellingAndRestoringAShootReachTheSnapshot() throws {
        let ctx = try context()
        let snapshot = AvailabilitySnapshot(loadExport: { self.export })
        snapshot.attach(to: ctx)
        defer { snapshot.detach() }
        #expect(snapshot.calendar.days.contains { $0.name == "Nguyen Recital" })

        CancelledShootEditing.cancel(bookingIds: ["b1"], named: "Nguyen Recital", on: "2026-11-18",
                                     export: export, in: ctx)
        #expect(!snapshot.calendar.days.contains { $0.name == "Nguyen Recital" })

        CancelledShootEditing.restore(bookingIds: ["b1"], export: export, in: ctx)
        #expect(snapshot.calendar.days.contains { $0.name == "Nguyen Recital" })
    }

    // A sweep of a DIFFERENT store must not repaint this one. A test sweeping an in-memory store would
    // otherwise change the calendar of the app hosting the tests.
    @Test func aSweepOfAnotherStoreIsIgnored() throws {
        let mine = try context()
        let theirs = try context()
        let snapshot = AvailabilitySnapshot(loadExport: { (bookings: [], blockedDates: [], health: .ok) })
        snapshot.attach(to: mine)
        defer { snapshot.detach() }

        DayOffEditing.add(start: "2026-11-20", end: "2026-11-21", note: "Away",
                          export: (bookings: [], blockedDates: [], health: .ok), into: theirs)

        #expect(snapshot.calendar.days.isEmpty)
        #expect(snapshot.builds == 1)
    }

    // Detached, it stops listening, so a torn down window scene leaves nothing dispatching.
    @Test func aDetachedSnapshotStopsListening() throws {
        let ctx = try context()
        let snapshot = AvailabilitySnapshot(loadExport: { (bookings: [], blockedDates: [], health: .ok) })
        snapshot.attach(to: ctx)
        snapshot.detach()

        DayOffEditing.add(start: "2026-11-20", end: "2026-11-21", note: "Away",
                          export: (bookings: [], blockedDates: [], health: .ok), into: ctx)

        #expect(snapshot.builds == 1)
    }

    // The two view bodies this issue is about no longer build a calendar or decode the export. Asked of
    // the source because neither view can be rendered in this target.
    @Test func neitherViewBodyBuildsTheCalendar() throws {
        // The sheet is a view and nothing else, so nothing in it may build or decode.
        let sheet = SourceGuardHelper.source("Overture/UI/DaysOffView.swift")
        #expect(!sheet.isEmpty, "DaysOffView.swift did not resolve; this guard measured nothing")
        #expect(!sheet.contains("blockedCalendar("), "the Days off sheet builds its own calendar again")
        #expect(!sheet.contains("DownbeatBridge.loadedExport()"),
                "the Days off sheet decodes the export itself again; the snapshot carries the bookings")

        // RootView legitimately builds one where a scout extract is INGESTED (a run, not a redraw), so this
        // asks of the toolbar mark's own property rather than of the whole file (L135).
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        let reason = try #require(SourceGuardHelper.propertyBody(
            "private var daysOffReason: DaysOffAttention.Reason {", in: root),
            "expected RootView.daysOffReason; this guard measured nothing")
        #expect(!reason.contains("blockedCalendar("), "the toolbar mark builds the calendar per redraw again")
        #expect(!reason.contains("loadedExport("), "the toolbar mark decodes the export per redraw again")
        #expect(reason.contains("availability.calendar"))
    }
}
