import Testing
import Foundation
import SwiftData

// #3766: a stored run and an incoming one that SHARE run member URLs, at one venue, under a character
// identical title, must be recognised as one show. `ScoutService.matchByAnyRunURL` exists to do exactly
// that and has been in the tree unchanged since 2026-06-25 (031f0a0d, #132).
//
// The measurement that produced this suite, on the live store 2026-09-10: `The New York Neo-Futurists:
// The Infinite Wrench` at Asylum NYC is stored FIFTEEN times, from ONE source, with no `seriesId` on any
// row. Four of those carry grouped runs whose `runSourceURLs` are nested subsets of each other, pk 312's
// twenty being a strict subset of pk 306's twenty two. Both guards on that arm pass trivially there: the
// venue strings are identical and `GroupNameMatch.isConfident` returns true on its first branch for
// identical token lists. So the arm should have re-keyed rather than inserted, and did not.
//
// This drives the real ingest (`ScoutService.apply`) rather than the private arm, because what is being
// asked is what the PIPELINE does, and #3766 lists a path other than this one as a candidate cause. A
// test calling the arm directly could only ever confirm the arm in isolation, which is not the claim.
//
// WHAT IT MEASURED, 2026-09-10: it PASSES. One row. So the arm fires correctly on the simple case, and
// #3766's original framing, that the arm is broken, is refuted and has been withdrawn on the issue.
//
// It is kept as a POSITIVE CONTROL rather than deleted, and that is deliberate. It is the thing that says
// the simple case works, which is what narrows the search for the real cause to what the fixture does NOT
// reproduce: a store already holding eight fragments of the same show, and a batch whose events group
// into several runs rather than one. It also goes red if somebody breaks the simple case while chasing
// the complex one. A test that only ever passes is worth keeping when what it pins is the boundary of a
// live investigation, and worth deleting when it is not, so this comment is the record of which it is.
//
// The dates are the real ones, and `today` is pinned to the day of the second ingest, so the pair's
// meaning cannot drift as real time passes them (L130).
// @MainActor because ScoutService is, and because a SwiftData container is main actor bound.
@MainActor
@Suite("A run sharing member URLs is one show (#3766)")
struct RunURLRecognitionTests {

    private static let title = "The New York Neo-Futurists: The Infinite Wrench"
    private static let venue = "Asylum NYC"
    private static let slug = "https://www.tixr.com/groups/asylumnyc/events/"
        + "the-new-york-neo-futurists-the-infinite-wrench-"

    // The nights pk 306 carried on 2026-07-31, paired with the per performance ids the feed publishes.
    private static let storedNights: [(String, String)] = [
        ("2026-07-31", "197818"), ("2026-08-01", "197819"), ("2026-08-07", "197820"),
        ("2026-08-08", "197821"), ("2026-08-14", "199142"), ("2026-08-15", "199145"),
        ("2026-08-21", "199146"), ("2026-08-22", "199147"), ("2026-08-28", "199155"),
        ("2026-08-29", "199348"), ("2026-09-04", "200734"), ("2026-09-05", "200735"),
    ]

    // What the feed published on 2026-08-07, once the first two nights had played: the same run, minus
    // its opening nights, so every remaining URL is one the stored row already holds.
    private static var incomingNights: [(String, String)] { Array(storedNights.dropFirst(2)) }

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    private func storedRun(in context: ModelContext) {
        let nights = Self.storedNights.map(\.0)
        let urls = Self.storedNights.map { Self.slug + $0.1 }
        let key = Prospect.makeNaturalKey(groupName: Self.title,
                                          performanceDate: nights.first,
                                          venue: Self.venue)
        // Every non defaulted field is supplied because the initialiser demands it. None of them is read
        // by the recognition arms under test, which key on the URLs, the venue and the title, so they are
        // ordinary values rather than a fixture pretending to mean something.
        let p = Prospect(naturalKey: key, groupName: Self.title, discipline: "theater",
                         venue: Self.venue, performanceDate: nights.first,
                         sourceListingURL: urls.first, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown",
                         fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nights.last, partOfRelatedRun: true, runSourceURLs: urls,
                         runNights: nights)
        context.insert(p)
    }

    private func incomingEvents() -> [ExtractedEvent] {
        Self.incomingNights.map { night, id in
            ExtractedEvent(title: Self.title, presenter: "The New York Neo-Futurists", venue: Self.venue,
                           performanceDate: night, sourceUrl: Self.slug + id)
        }
    }

    // THE CLAIM. Two ingests of one production, the second sharing every URL with the first, leave ONE row.
    @Test func aSecondIngestSharingEveryRunURLDoesNotMintASecondRow() throws {
        let ctx = ModelContext(try container())
        storedRun(in: ctx)
        try ctx.save()

        _ = ScoutService.apply(events: incomingEvents(), clients: [], history: [],
                               blocked: .empty, today: "2026-08-07",
                               sourceIds: ["calendar-asylumnyc-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let mine = rows.filter { $0.groupName == Self.title }
        let keys = mine.map(\.naturalKey).sorted()
        #expect(mine.count == 1,
                "one production is stored \(mine.count) times though the stored row already held every incoming run URL (#3766): \(keys)")
    }

    // The evidence the arm is supposed to read, asserted separately so a failure above can be told from a
    // fixture that never shared a URL at all. A test that cannot show the precondition held proves nothing
    // about the rule (L159).
    @Test func theFixtureReallyDoesShareEveryIncomingURLWithTheStoredRun() {
        let stored = Set(Self.storedNights.map { Self.slug + $0.1 })
        let incoming = Set(Self.incomingNights.map { Self.slug + $0.1 })
        #expect(!incoming.isEmpty)
        #expect(incoming.isSubset(of: stored),
                "the fixture does not reproduce the live shape: the incoming run must share every URL")
    }
}
