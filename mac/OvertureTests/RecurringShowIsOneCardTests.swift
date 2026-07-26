import Testing
import Foundation
@testable import Overture

// #1558: the duplicate cards Dan can actually SEE. Measured on the live store 2026-07-26: 36 rows across
// 10 shows, worst `The New York Neo-Futurists: The Infinite Wrench` at Asylum NYC with TWELVE cards for
// one weekly show. None of them carry a feed production id, so #1528's fix cannot reach them, and unlike
// the id-tagged duplicates they can never self-retire: their listing URLs stay in the feed, so
// `FeedReconcile.isStillListed` keeps `missedScoutCount` at 0 forever. They sit in the queue indefinitely.
//
// TWO causes stacked, both reproduced below.
//
// 1. The gap walk is ORDER DEPENDENT. It scans a venue's rows in date order and only joins a row to the
//    one immediately before it, so any other show at that venue breaks the chain. Live proof at Asylum
//    NYC: Neo-Futurists 08-07, Marcus Monroe 08-08, Neo-Futurists 08-08. The two Neo nights are ONE day
//    apart and belong together; Marcus Monroe sitting between them in the sort stranded each in its own
//    run. This is the same defect the seriesId path was given its own clustering to avoid, and its comment
//    says so: "a sequential walk would strand a later night in its own run".
//
// 2. The joining window was three days, so a WEEKLY show splits however cleanly it is clustered.
//
// WHY THE WINDOW CAN WIDEN NOW. It was tight because a long run used to be conflict-checked against every
// day in its span, so collapsing a weekly series invented false clashes against Dan's calendar. #1523
// removed that: a run is now judged on the nights it actually plays. Dan chose EIGHT WEEKS (2026-07-26),
// between "any gap" and the old three days, and it follows his standing rule that he pitches a run once
// rather than once a week ([[dan-pitches-a-run-once-not-every-night]]).
//
// `RunGrouping.gapDays` stays at 3 and is NOT what widened: `EngagementLink.swift:50` uses it to link one
// production across DIFFERENT venues, and `DuplicateContactGuard` mirrors it. Widening that would change
// how often Dan may contact the same org, which is a different question nobody asked.
@Suite("A recurring show at one venue is one card (#1558)")
struct RecurringShowIsOneCardTests {

    private var nextId = 0

    private func row(_ date: String, _ title: String, venue: String = "Asylum NYC",
                     id: Int) -> RunGrouping.RunRow {
        RunGrouping.RunRow(id: id, groupName: title, venue: venue, performanceDate: date,
                           sourceListingURL: "https://asylumnyc.example/e/\(id)", seriesId: nil)
    }

    private let neo = "The New York Neo-Futurists: The Infinite Wrench"

    // Dan's worst case, from the live store: a weekly show that produced twelve cards.
    @Test func aWeeklyShowIsOneCardListingAllItsNights() {
        let nights = ["2026-07-31", "2026-08-07", "2026-08-14", "2026-08-21",
                      "2026-08-28", "2026-09-04", "2026-09-11"]
        let rows = nights.enumerated().map { row($0.element, neo, id: $0.offset) }

        let runs = RunGrouping.group(rows)

        #expect(runs.count == 1, "one weekly show is one engagement Dan pitches once")
        #expect(runs.first?.row.performanceDate == "2026-07-31")
        #expect(runs.first?.runEndDate == "2026-09-11")
        #expect(runs.first?.memberDates == nights)
    }

    // Cause 1, exactly as it happens at Asylum NYC. Marcus Monroe plays between two Neo-Futurist nights
    // that are one day apart. Before the fix that stranded both Neo nights in runs of their own.
    @Test func anotherShowOnTheSameNightDoesNotBreakTheRun() {
        let rows = [row("2026-07-31", neo, id: 1),
                    row("2026-08-07", neo, id: 2),
                    row("2026-08-08", "Marcus Monroe", id: 3),
                    row("2026-08-08", neo, id: 4),
                    row("2026-08-14", neo, id: 5)]

        let runs = RunGrouping.group(rows)

        #expect(runs.count == 2)
        let wrench = runs.first { $0.row.groupName == neo }
        #expect(wrench?.memberDates == ["2026-07-31", "2026-08-07", "2026-08-08", "2026-08-14"])
        #expect(runs.first { $0.row.groupName == "Marcus Monroe" }?.memberDates == ["2026-08-08"])
    }

    // Monday Night Magic in the live store: three cards, all from ONE listing URL, spaced four weeks and
    // then one week apart. Inside eight weeks, so one card.
    @Test func aMonthlyShowStillJoins() {
        let rows = [row("2026-11-23", "Monday Night Magic", venue: "The Cutting Room", id: 1),
                    row("2026-12-21", "Monday Night Magic", venue: "The Cutting Room", id: 2),
                    row("2026-12-28", "Monday Night Magic", venue: "The Cutting Room", id: 3)]

        #expect(RunGrouping.group(rows).count == 1)
    }

    // The far edge of Dan's window. A silence longer than eight weeks is a separate engagement and gets
    // its own card, so a show returning after a season break is still something he is asked about.
    @Test func aGapLongerThanEightWeeksStartsANewCard() {
        let rows = [row("2026-07-31", neo, id: 1),
                    row("2026-08-07", neo, id: 2),
                    row("2026-11-06", neo, id: 3)]      // 91 days after the 8th

        let runs = RunGrouping.group(rows)

        #expect(runs.count == 2)
        #expect(runs.first { $0.row.performanceDate == "2026-11-06" }?.memberDates == ["2026-11-06"])
    }

    // Just inside the window still joins, so the boundary is where Dan put it and not a day off.
    @Test func exactlyEightWeeksApartStillJoins() {
        let rows = [row("2026-08-01", neo, id: 1),
                    row("2026-09-26", neo, id: 2)]      // 56 days

        #expect(RunGrouping.group(rows).count == 1)
    }

    // The guard that matters most: widening the window must never fuse two genuinely different acts that
    // happen to share a venue and a season.
    @Test func twoDifferentShowsAtOneVenueNeverMerge() {
        let rows = [row("2026-08-01", "Gross Prophets: A Comedy Musical", id: 1),
                    row("2026-08-08", neo, id: 2),
                    row("2026-08-15", "Gross Prophets: A Comedy Musical", id: 3)]

        let runs = RunGrouping.group(rows)

        #expect(runs.count == 2)
        #expect(runs.first { $0.row.groupName == neo }?.memberDates == ["2026-08-08"])
    }

    // And the same show at a DIFFERENT venue is a different engagement, which is what EngagementLink
    // exists to relate rather than what this collapses.
    @Test func theSameShowAtAnotherVenueIsItsOwnRun() {
        let rows = [row("2026-08-01", neo, id: 1),
                    row("2026-08-08", neo, venue: "The Cutting Room", id: 2)]

        #expect(RunGrouping.group(rows).count == 2)
    }

    // The shared window this must NOT have touched. EngagementLink uses RunGrouping.gapDays to decide how
    // many dark days still count as one engagement ACROSS venues, and DuplicateContactGuard mirrors it to
    // pace how often Dan may contact one org. Neither question was asked here, so neither answer moved.
    @Test func theCrossVenueEngagementWindowIsUnchanged() {
        #expect(RunGrouping.gapDays == 3)
    }
}
