import Testing
import Foundation
import SwiftData
@testable import Overture

// #1528: a run's identity must survive its own opening night moving.
//
// A prospect's natural key is `groupName|performanceDate|venue`, and for a grouped run that date is the
// OPENING night (RunGrouping takes the series cluster's first row). The scout reads a forward window, so
// once a night has passed it leaves the feed and the run's first REMAINING performance advances. New
// opening night, new key, new prospect, every single day. Dan dismissed `Hungry Women` at SoHo Playhouse
// on 2026-07-23 and it came back on the 24th, the 25th and the 26th.
//
// Four match arms in ScoutService were supposed to prevent exactly this (#132: "so Dan's keep/dismiss
// decision survives across run-window shifts"). All four miss for these rows: the key drifts by
// construction, both URL arms need a `sourceListingURL` that OvationTix and VenueTix deliberately pass as
// nil, and the concert-identity arm is gated to synthetic same-date ids so a REAL feed production id never
// matches. This is not a missing feature; it is one arm scoped narrower than the evidence it is handed.
//
// WHY THE WIDENING IS NOT SIMPLY "TRUST ANY seriesId". A red-team pass found the field is not reliably a
// production id: the extract runbook tells the paid AI to copy any "Series:" marker off a page verbatim,
// and a page reading "Series: Broadway Sessions" is a SEASON spanning many different productions.
// Matching on that would re-key a stored prospect onto a different show while keeping its dismissal, send
// record and thread id, which is the #797 failure this codebase already paid for once. So a feed id
// carries identity only with two corroborations that a season marker cannot fake:
//
//   1. the titles must be the same act (GroupNameMatch), and
//   2. the incoming opening night must fall INSIDE the stored run's own dates.
//
// (2) also disposes of the revival problem for free and with no magic constant: a run whose start creeps
// forward is always still inside its own window, and a remount next season never is, so it correctly
// gets its own card instead of silently inheriting a dismissal.
@Suite("A run keeps its identity when its opening night moves (#1528)")
struct RunIdentitySurvivesDriftTests {

    private let venue = "SoHo Playhouse"
    private let feedId = "1280419"          // the real OvationTix production id, from Dan's live store

    // Deliberately `sourceUrl: nil`: that is what OvationTixCalendar and VenueTixCalendar actually pass
    // (OvationTixCalendar.swift:233, VenueTixCalendar.swift:205), and it is why the two URL match arms
    // cannot rescue these rows. A test that supplied a URL would pass through a different arm entirely and
    // prove nothing about the one under repair.
    private func night(_ date: String, title: String = "Hungry Women", at venue: String? = nil,
                       series: String? = nil) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: nil, venue: venue ?? self.venue, performanceDate: date,
                       sourceUrl: nil, location: "New York, NY", seriesId: series ?? feedId)
    }

    private func ctx() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func prospects(_ context: ModelContext) throws -> [Prospect] {
        try context.fetch(FetchDescriptor<Prospect>())
    }

    // The live case, exactly. Sweep A sees the run opening 2026-07-23 and closing 2026-08-30. By sweep B
    // the 23rd has played and left the feed, so the run now opens on the 24th. One show, one card.
    @MainActor
    @Test func aRunWhoseOpeningNightAdvancesUpdatesInPlace() throws {
        let context = try ctx()

        _ = ScoutService.apply(events: [night("2026-07-23"), night("2026-08-30")], clients: [], history: [],
                               blocked: .empty, today: "2026-07-23", into: context)
        #expect(try prospects(context).count == 1)

        _ = ScoutService.apply(events: [night("2026-07-24"), night("2026-08-30")], clients: [], history: [],
                               blocked: .empty, today: "2026-07-24", into: context)

        #expect(try prospects(context).count == 1)
    }

    // The harm this issue is actually worth fixing for. Not card clutter (FeedReconcile retires the
    // orphans on its own once each night passes) but that Dan is asked again about a show he refused.
    @MainActor
    @Test func aDismissalSurvivesTheOpeningNightAdvancing() throws {
        let context = try ctx()

        _ = ScoutService.apply(events: [night("2026-07-23"), night("2026-08-30")], clients: [], history: [],
                               blocked: .empty, today: "2026-07-23", into: context)
        let kept = try #require(try prospects(context).first)
        kept.statusRaw = ReviewStatus.dismissed.rawValue
        kept.dismissReasonRaw = "too_soon"
        try context.save()

        for (today, opening) in [("2026-07-24", "2026-07-24"), ("2026-07-25", "2026-07-25"),
                                 ("2026-07-26", "2026-07-26")] {
            _ = ScoutService.apply(events: [night(opening), night("2026-08-30")], clients: [], history: [],
                                   blocked: .empty, today: today, into: context)
        }

        let all = try prospects(context)
        #expect(all.count == 1)
        #expect(all.first?.statusRaw == ReviewStatus.dismissed.rawValue)
        #expect(all.first?.dismissReasonRaw == "too_soon")
    }

    // The drift is not only forward. Jena Friedman in the live store went the OTHER way: the row ingested
    // 2026-07-23 opens 2026-10-02 and the row ingested 2026-07-26 opens 2026-10-01, because the feed GAINED
    // an earlier performance. A test that only advances the opening night would miss half the fault.
    @MainActor
    @Test func aRunThatGainsAnEarlierNightAlsoUpdatesInPlace() throws {
        let context = try ctx()

        _ = ScoutService.apply(events: [night("2026-10-02"), night("2026-10-11")], clients: [], history: [],
                               blocked: .empty, today: "2026-07-23", into: context)
        #expect(try prospects(context).count == 1)

        _ = ScoutService.apply(events: [night("2026-10-01"), night("2026-10-11")], clients: [], history: [],
                               blocked: .empty, today: "2026-07-26", into: context)

        #expect(try prospects(context).count == 1)
    }

    // The revival guard, and the reason the window test is worth more than a date constant. The venue
    // remounts the same production next spring under the same feed id. That is a NEW run Dan has never
    // been asked about, and it must not inherit the old one's dismissal and vanish.
    @MainActor
    @Test func aRemountOutsideTheStoredRunGetsItsOwnCard() throws {
        let context = try ctx()

        _ = ScoutService.apply(events: [night("2026-07-23"), night("2026-08-30")], clients: [], history: [],
                               blocked: .empty, today: "2026-07-23", into: context)
        let first = try #require(try prospects(context).first)
        first.statusRaw = ReviewStatus.dismissed.rawValue
        try context.save()

        _ = ScoutService.apply(events: [night("2027-03-01"), night("2027-03-20")], clients: [], history: [],
                               blocked: .empty, today: "2026-08-31", into: context)

        let all = try prospects(context)
        #expect(all.count == 2, "a remount months after the stored run closed is a new show to pitch")
        #expect(all.contains { $0.statusRaw == ReviewStatus.new.rawValue })
    }

    // The #797 guard. A season marker ("Series: Broadway Sessions") is exactly the shape the extract
    // runbook tells the AI to copy, and it spans genuinely different productions at one venue. Sharing it
    // must never fuse them, or a dismissal, a sent email and a thread id end up attached to a show they
    // have nothing to do with.
    @MainActor
    @Test func twoDifferentShowsSharingASeriesMarkerAreNeverFused() throws {
        let context = try ctx()
        let marker = "broadway-sessions"

        _ = ScoutService.apply(events: [night("2026-09-01", title: "An Evening with Rossini", series: marker),
                                        night("2026-09-08", title: "An Evening with Rossini", series: marker)],
                               clients: [], history: [], blocked: .empty, today: "2026-07-23", into: context)
        _ = ScoutService.apply(events: [night("2026-09-15", title: "The Sondheim Songbook", series: marker),
                                        night("2026-09-22", title: "The Sondheim Songbook", series: marker)],
                               clients: [], history: [], blocked: .empty, today: "2026-07-24", into: context)

        #expect(try prospects(context).count == 2, "one season marker is not one production")
    }

    // A feed id is only unique within its own source. The same numeric id arriving from a different
    // venue's feed is a different show.
    @MainActor
    @Test func theSameFeedIdAtADifferentVenueIsNeverFused() throws {
        let context = try ctx()

        _ = ScoutService.apply(events: [night("2026-09-01"), night("2026-09-08")], clients: [], history: [],
                               blocked: .empty, today: "2026-07-23", into: context)
        _ = ScoutService.apply(events: [night("2026-09-02", at: "The Cutting Room"),
                                        night("2026-09-09", at: "The Cutting Room")],
                               clients: [], history: [], blocked: .empty, today: "2026-07-23", into: context)

        #expect(try prospects(context).count == 2)
    }

    // A row carrying NO feed id is untouched by any of this: it still goes through the gap-and-title walk
    // and the URL arms exactly as before. That path has its own duplicate problem (#1558, 36 cards Dan can
    // actually see) which this fix deliberately does not claim to solve.
    @MainActor
    @Test func aRowWithNoFeedIdIsUnaffected() throws {
        let context = try ctx()

        _ = ScoutService.apply(events: [ExtractedEvent(title: "Solo Recital", presenter: nil, venue: venue,
                                                       performanceDate: "2026-09-01", sourceUrl: nil,
                                                       location: "New York, NY", seriesId: nil)],
                               clients: [], history: [], blocked: .empty, today: "2026-07-23", into: context)

        #expect(try prospects(context).count == 1)
        #expect(try prospects(context).first?.seriesId == nil)
    }
}
