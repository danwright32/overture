import Testing
import Foundation
import SwiftData
@testable import Overture

// #1663: a show found by two sources took the genre of whichever source's run finished last.
//
// `ScoutExtractIngest` loops per source and calls `ScoutService.apply` once each, and every non-override
// arm of `apply` wrote `existing.discipline = p.discipline` outright. The provenance three lines away is
// a UNION, with a comment explaining why a replace there would be wrong; the classification was a replace
// with no rule at all. So the stored genre was decided by iteration order, and a genre is not only a
// label: `Discipline.staysInTheBoroughs` makes music and band take the strict five-borough rule while
// everything else travels the region, so a nondeterministic genre is a nondeterministic decision about
// whether a show appears in the queue at all.
//
// These drive the REAL ingest, both orders, because the defect IS the order. Testing the rule in
// isolation would prove the rule and say nothing about the wiring, which is the #887 mistake.
@MainActor
@Suite("Two sources disagreeing about one show's genre (#1663)")
struct GenrePrecedenceTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @discardableResult
    private func source(_ ctx: ModelContext, _ id: String) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.pendingContentHash = "new-hash-\(id)"
        s.hasUnreadChanges = true
        s.successfulCheckCount = WatchedSource.warmupRuns
        s.baselineFeedCount = 1
        ctx.insert(s)
        return s
    }

    // ONE show, spelled the same way by both sources, so both land on one row: the natural key is title,
    // date and venue, and the presenter is not in it. The two sources differ ONLY in whether they name
    // the presenting organisation, which is the real shape (a hand-added lead carries none; the venue's
    // own feed carries one).
    private let title = "A Man Called Paris"          // carries no genre word of its own
    private let venue = "Under St Marks"

    private func event(namingPresenter presenter: String?) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: presenter, venue: venue,
                          performanceDate: "2099-10-01",
                          sourceUrl: "https://example.test/a-man-called-paris")
    }

    private func ingest(_ perSource: [(String, [ScoutExtractEvent])], into ctx: ModelContext) {
        let results = ScoutExtractResults(
            version: 1, generatedAt: "2026-07-13T00:00:00Z",
            results: perSource.map { id, events in
                ScoutExtractResult(sourceId: id, verdict: .upcomingListings, events: events, note: nil)
            })
        ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
    }

    private func storedGenre(_ ctx: ModelContext) throws -> String? {
        try #require((try? ctx.fetch(FetchDescriptor<Prospect>()))?.first).discipline
    }

    // Non-vacuous: the two events really do classify differently, or every test below proves nothing.
    @Test func theTwoSpellingsOfThisShowGenuinelyDisagree() {
        #expect(EventClassifier.classify(event(namingPresenter: "Brooklyn Youth Chorus").asExtractedEvent)
                    .discipline == .music)
        #expect(EventClassifier.classify(event(namingPresenter: nil).asExtractedEvent)
                    .discipline == .other)
    }

    // THE defect. The source that could read the genre ran FIRST, so the one that could not ran last and
    // erased it. A genre that was read must not lose to one that was not.
    @Test func aSourceThatCannotReadTheGenreDoesNotEraseOneThatCould() throws {
        let ctx = try context()
        source(ctx, "frigid")
        source(ctx, "manual-lead")

        ingest([("frigid", [event(namingPresenter: "Brooklyn Youth Chorus")]),
                ("manual-lead", [event(namingPresenter: nil)])], into: ctx)

        #expect(try storedGenre(ctx) == "music")
    }

    // The same two facts in the other order must reach the same answer, which is what "no precedence
    // rule" cost: this order already passed, and the one above did not, for no reason but iteration.
    @Test func theOppositeOrderReachesTheSameGenre() throws {
        let ctx = try context()
        source(ctx, "frigid")
        source(ctx, "manual-lead")

        ingest([("manual-lead", [event(namingPresenter: nil)]),
                ("frigid", [event(namingPresenter: "Brooklyn Youth Chorus")])], into: ctx)

        #expect(try storedGenre(ctx) == "music")
    }

    // The rule must not become "first read wins", which would be deterministic and WRONG: `apply` runs
    // for the same source on every scout, so a source that corrects its own listing has to be able to
    // move the genre it set. Only a DIFFERENT source is held off.
    @Test func aSourceMayStillCorrectItsOwnEarlierReading() throws {
        let ctx = try context()
        source(ctx, "frigid")

        ingest([("frigid", [event(namingPresenter: "Brooklyn Youth Chorus")])], into: ctx)
        #expect(try storedGenre(ctx) == "music")

        // The same source, next run, no longer naming the organisation.
        source(ctx, "frigid").hasUnreadChanges = true
        ingest([("frigid", [event(namingPresenter: nil)])], into: ctx)

        #expect(try storedGenre(ctx) == "other")
    }

    // The whole classification moves together or the row describes two different shows: `fitReason` is
    // built from the discipline, production, profile and coverage of ONE classify call, so keeping the
    // genre while taking a second source's reason would print a sentence about a genre the row does not
    // hold. #1664 is open on that sentence being read by Dan.
    @Test func theKeptClassificationKeepsItsOwnReason() throws {
        let ctx = try context()
        source(ctx, "frigid")
        source(ctx, "manual-lead")

        ingest([("frigid", [event(namingPresenter: "Brooklyn Youth Chorus")]),
                ("manual-lead", [event(namingPresenter: nil)])], into: ctx)

        let row = try #require((try? ctx.fetch(FetchDescriptor<Prospect>()))?.first)
        #expect(row.discipline == "music")
        #expect(!row.fitReason.contains("other"),
                "the kept genre and the printed reason must describe the same show: \(row.fitReason)")
    }
}
