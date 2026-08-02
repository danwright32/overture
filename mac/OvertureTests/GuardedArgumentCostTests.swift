import Testing
import Foundation
import SwiftData
@testable import Overture

// #1960: expensive work built as an argument to a function whose first line throws it away.
//
// Swift evaluates arguments before the call, so a guard reads as though it makes the path cheap while the
// cost is already paid. #1916 named the shape once; this is the sweep for the rest of it.
//
// Each of these measures the cost with a counting closure rather than asserting that a closure exists,
// because the defect is invisible from the outside: the answer is identical either way, and only what was
// paid for it changes.
@MainActor
@Suite("A guard that refuses must refuse the cost too (#1960)")
struct GuardedArgumentCostTests {

    // The instance the issue names. Dismissing a show builds the whole touring engagement (a sweep of
    // every undismissed prospect, with name folding and date arithmetic per row) and hands it over, and
    // six of the eight dismiss reasons are not calendar reasons at all.
    @Test func aNonCalendarDismissNeverBuildsTheEngagement() {
        var built = 0
        let linked = { () -> [String] in
            built += 1
            return ["2026-09-12"]
        }

        let offer = DayOffOffer.offer(reason: .dontWantToShoot, performanceDate: "2026-09-11",
                                      runEndDate: nil, linkedDates: linked())

        #expect(offer == nil)
        #expect(built == 0, "a reason that is not about the calendar must not pay for the engagement")
    }

    // The other refusal: the night is already blocked, so there is nothing to capture.
    @Test func aDismissOnAnAlreadyBlockedNightNeverBuildsTheEngagement() {
        var built = 0
        let linked = { () -> [String] in
            built += 1
            return ["2026-09-12"]
        }

        let offer = DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-09-11",
                                      runEndDate: nil, linkedDates: linked(), alreadyBlocked: true)

        #expect(offer == nil)
        #expect(built == 0)
    }

    // And when the offer IS made, the engagement is read exactly once and still widens the range, so the
    // saving cannot have come from quietly dropping the feature (#939).
    @Test func aCalendarDismissStillWidensTheOfferToTheWholeEngagement() {
        var built = 0
        let linked = { () -> [String] in
            built += 1
            return ["2026-09-14"]
        }

        let offer = DayOffOffer.offer(reason: .dateConflict, performanceDate: "2026-09-11",
                                      runEndDate: nil, linkedDates: linked())

        #expect(built == 1)
        #expect(offer?.start == "2026-09-11")
        #expect(offer?.end == "2026-09-14")
    }

    // Found by the sweep. The days-off mark reads and decodes the Downbeat export and fetches the stored
    // days off to build a calendar, and the first line of the rule that reads it returns as soon as Dan
    // has snoozed the mark.
    @Test func aSnoozedDaysOffMarkNeverBuildsTheCalendar() {
        let defaults = UserDefaults(suiteName: "geo-1960-\(UUID().uuidString)")!
        defaults.set(Date().addingTimeInterval(3_600).timeIntervalSince1970, forKey: DaysOffAttention.snoozeKey)
        var built = 0
        let calendar = { () -> BlockedCalendar in
            built += 1
            return BlockedCalendar.build(bookings: [], exportedBlockedDates: [], daysOff: [])
        }

        let reason = DaysOffAttention.reason(calendar(), defaults: defaults)

        #expect(reason == .none)
        #expect(built == 0, "a snoozed mark must not read the export to decide it has nothing to say")
    }

    // And an un-snoozed mark still reads it and still answers, so the guard has not swallowed the feature.
    @Test func anUnsnoozedDaysOffMarkStillReadsTheCalendarAndAnswers() {
        let defaults = UserDefaults(suiteName: "geo-1960-\(UUID().uuidString)")!
        var built = 0
        let calendar = { () -> BlockedCalendar in
            built += 1
            return BlockedCalendar.build(bookings: [], exportedBlockedDates: [], daysOff: [])
        }

        let reason = DaysOffAttention.reason(calendar(), defaults: defaults)

        #expect(built == 1)
        #expect(reason == .noUpcomingShoots)
    }

    // Found by the sweep. The booking reconcile fetches every prospect and every inquiry and boxes each
    // one, then hands them to a pass that does nothing at all unless the Downbeat export is healthy.
    @Test func anUnhealthyExportNeverFetchesTheEntitiesToReconcile() {
        var built = 0
        let entities = { () -> [any BookingMatchable] in
            built += 1
            return []
        }

        let changed = DownbeatBooking.reconcileBooked(entities: entities(), clients: [], bookings: [],
                                                      health: .missing, now: Date())

        #expect(changed == 0)
        #expect(built == 0, "no export means no reconcile, so the store must not be swept for one")
    }

    // A healthy export still reads them, so the refusal above is about the cost and not about the work.
    @Test func aHealthyExportStillReadsTheEntities() {
        var built = 0
        let entities = { () -> [any BookingMatchable] in
            built += 1
            return []
        }

        _ = DownbeatBooking.reconcileBooked(entities: entities(), clients: [], bookings: [],
                                            health: .ok, now: Date())

        #expect(built == 1)
    }
}

// The days-off mark is read three times to draw one toolbar button, and each read is a file decode and a
// store fetch. Reading it once per pass is the same #1916 lesson one level up: the expression is at the
// call site, so it is paid at the call site, however cheap the thing it is handed to looks.
@Suite("The days-off mark is worked out once per pass (#1960)")
struct DaysOffMarkReadOnceTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func theToolbarWorksTheMarkOutOnceAndHandsItDown() {
        #expect(!rootView.isEmpty)
        // Once at the call site, handed to the button that draws all three of its states.
        #expect(rootView.contains("daysOffButton(daysOffReason)"))
        // And nowhere else: three reads of a computed property is three file decodes.
        #expect(rootView.components(separatedBy: "daysOffReason").count - 1 == 3,
                "expected the definition, its doc mention and exactly one read")
    }
}
