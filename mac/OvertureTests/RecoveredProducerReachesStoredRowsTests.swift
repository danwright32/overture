import Testing
import Foundation
import SwiftData

// #2259, the BACKFILL, which is a separate claim from the parse.
//
// `ProducerShapedName`, read by the VenueTix adapter, recovers a producing company the ingest used to throw
// away, and that fixes the NEXT show. It says nothing about the 438 organiser-less prospects already in
// Dan's store: 150 of them at The Green Room 42, whose feed carries the producer for roughly one in seven.
// Shipping the parse and leaving those exactly as they are would have been the whole issue's cost paid and
// none of its benefit collected.
//
// Nothing has to be migrated for them, and this suite is what proves that rather than assuming it. Two
// facts do the work together, and neither is enough alone:
//
//   1. A VenueTix source uses the NATIVE extractor, so it is parsed on EVERY scout run, free, including
//      the automatic daily watch-only one. It is never hash-gated out the way a paid html read is
//      (`SourceSchedule.plan` puts `native` in every plan whatever the depth).
//   2. The ingest WRITES the presenter onto a row it already holds, rather than only onto one it inserts.
//
// The second is the one that could silently not be true, and the one this suite pins: a "keep what we
// already stored" rule anywhere on that path would leave every one of those 150 rows organiser-less
// forever while every test about the parse stayed green.
@Suite("A recovered producer reaches the rows already stored (#2259)")
struct RecoveredProducerReachesStoredRowsTests {

    private let clearCalendar = BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: [], daysOff: [])

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    // The feed's own record for this show, as fetched 2026-08-07, through the real adapter rather than a
    // hand-built ExtractedEvent: a test that assembles the event itself proves nothing about what the
    // adapter emits.
    private func feedEvents(superTitle: String?) -> [ExtractedEvent] {
        let event = VenueTixCalendar.VTEvent(title: "Summer Lovin'", superTitle: superTitle, subTitle: nil,
                                             date: Date(timeIntervalSince1970: 1_786_000_000),
                                             eventId: "hHr5I9OT5vhNwIimQeaY", seriesId: nil)
        return VenueTixCalendar.extractedEvents(from: [event], presenter: "The Green Room 42",
                                                venue: "The Green Room 42",
                                                location: "New York, NY")
            // The same boundary the scout puts between the adapter and the ingest (#1766/#1788), in the
            // same order, which is what drains the room's own name and leaves these rows organiser-less.
            // Skip it here and the test would ingest a presenter no real run ever writes.
            .map(ExtractedEventGuard.presenterThatIsNotTheRoom)
    }

    private func today(_ events: [ExtractedEvent]) -> String {
        // A day before the show, so the upcoming-only guard keeps it.
        guard let date = events.first?.performanceDate else { return "2026-01-01" }
        return String(date.dropLast(2)) + "01"
    }

    // The state of a real organiser-less row: the room was billed as the presenter and Overture drained
    // it (#1787), so the field is empty and `presenterWasTheRoom` records why.
    @MainActor
    @Test func aStoredRowWithNoOrganiserGainsTheProducerTheFeedNames() throws {
        let ctx = try context()
        let asStoredBefore = feedEvents(superTitle: "For One Night Only")   // marketing: nothing to recover
        _ = ScoutService.apply(events: asStoredBefore, clients: [], history: [], blocked: clearCalendar,
                               today: today(asStoredBefore), into: ctx)

        let before = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        #expect(OrganiserNaming.onlyTheActIsNamed(presenter: before.presenter),
                "the row this test is about is the organiser-less one")

        // The same show, read again by a scout running the recovered parse.
        let recovered = feedEvents(superTitle: "ICB Productions'")
        _ = ScoutService.apply(events: recovered, clients: [], history: [], blocked: clearCalendar,
                               today: today(recovered), into: ctx)

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, "the same show must update the row, not add a second one")
        #expect(rows.first?.presenter == "ICB Productions")
        #expect(OrganiserNaming.onlyTheActIsNamed(presenter: rows.first?.presenter) == false)
    }

    // The other direction, and the reason this is safe to leave to the ordinary scout: a show whose
    // supertitle is marketing keeps the empty presenter it has. The recovery must not put a slogan in the
    // field on the way past.
    @MainActor
    @Test func aStoredRowWhoseFeedCarriesOnlyMarketingIsLeftAlone() throws {
        let ctx = try context()
        let first = feedEvents(superTitle: nil)
        _ = ScoutService.apply(events: first, clients: [], history: [], blocked: clearCalendar,
                               today: today(first), into: ctx)

        let again = feedEvents(superTitle: "Eating Everything!")
        _ = ScoutService.apply(events: again, clients: [], history: [], blocked: clearCalendar,
                               today: today(again), into: ctx)

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1)
        #expect(OrganiserNaming.onlyTheActIsNamed(presenter: rows.first?.presenter),
                "marketing is not a producer, so this row stays organiser-less")
    }

    // Fact 1 above, asserted rather than trusted to a comment: a native source is in EVERY plan, so the
    // rows above are re-read by the free daily run without Dan pressing anything. If this ever became
    // conditional, the recovery would wait on whichever run happened to include the feed.
    @MainActor
    @Test func aNativeFeedIsParsedByEveryRunIncludingTheFreeDailyOne() {
        let source = WatchedSource(sourceId: "green-room-42", orgName: "The Green Room 42",
                                   listingsURL: "https://greenroom42.venuetix.com/", kind: .venueTixFeed)
        source.lastContentHash = "unchanged-since-the-last-ingest"

        for depth in [ScoutDepth.watchOnly, ScoutDepth.readChanged] {
            let plan = SourceSchedule.plan(sources: [source], depth: depth, now: Date())
            #expect(plan.native.contains { $0.sourceId == "green-room-42" },
                    "a native feed must be parsed at depth \(depth), whatever its content hash says")
        }
    }
}
