import Testing
import Foundation
import SwiftData

// #4032: `ScoutService.matchByStableSource` re-keys a stored prospect onto an incoming one when the
// listing URL, the performance date and the folded venue all agree, and it deliberately does not test
// the title. Its own comment says why that is safe:
//
//   #797: the venue must agree as well. On a season page every show shares one listing URL, so URL +
//   date alone would re-key one show onto a DIFFERENT act that happens to play the same night.
//
// That reasoning holds where the shared listing spans several ROOMS. The shape this repository actually
// meets is a single venue's season page, where every show shares one URL and one venue, so adding the
// venue removes nothing. The guard names the failure it does not prevent.
//
// MEASURED ON THE LIVE STORE 2026-09-19, which is why this is not hypothetical. pk 625
// `Back to Shakespeare` and pk 627 `Marlise (A New Golden Age Musical)` both carry
// `sourceListingURL = www.theplayerstheatre.com/show-schedule.html`, `venue = The Players Theatre` and
// `performanceDate = 2026-09-04`. They are different shows and they satisfy the predicate exactly.
//
// WHAT THIS SUITE IS FOR. Those two rows both still exist, so on that data the arm did NOT fire, and
// #4032 says in as many words that the cause must be established before anything is changed (L681, and
// this milestone's own record of premises that were wrong about the mechanism). So this drives the real
// `ScoutService.apply` rather than the private arm, and asserts what the pipeline DOES. Whatever it
// says, it is the evidence the fix is designed from, and it is written before any fix exists.
//
// The window that matters is narrow and this fixture is built to sit in it. Once BOTH shows are stored,
// an incoming row matches its own natural key on the first arm and never reaches the fifth, which is
// why the live pair is stable. The exposure is a show appearing on the page for the FIRST time on a
// date another show from that page already occupies.
@MainActor
@Suite("A season page with two shows on one night (#4032)")
struct SeasonPageStableSourceTests {

    private static let page = "https://www.theplayerstheatre.com/show-schedule.html"
    private static let venue = "The Players Theatre"
    private static let night = "2026-09-04"

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, title: String) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: title, performanceDate: Self.night,
                                          venue: Self.venue)
        let p = Prospect(naturalKey: key, groupName: title, discipline: "theater", venue: Self.venue,
                         performanceDate: Self.night, sourceListingURL: Self.page,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [Self.page],
                         runNights: [Self.night])
        ctx.insert(p)
        return p
    }

    // THE CLAIM UNDER TEST. A second, genuinely different show appears on the same season page, on the
    // night the stored show already occupies. They must remain two rows.
    @Test func aSecondShowOnTheSamePageAndNightDoesNotTakeOverTheFirst() throws {
        let ctx = try context()
        let first = stored(ctx, title: "Marlise (A New Golden Age Musical)")
        first.statusRaw = ReviewStatus.dismissed.rawValue
        let firstKey = first.naturalKey
        try ctx.save()

        let incoming = ExtractedEvent(title: "Back to Shakespeare", presenter: "The Players Theatre",
                                      venue: Self.venue, performanceDate: Self.night,
                                      sourceUrl: Self.page)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-08-20", sourceIds: ["theplayerstheatre-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let titles = rows.map(\.groupName).sorted()
        #expect(rows.count == 2,
                "two different shows on one season page on one night are two shows: \(titles)")
        #expect(rows.contains { $0.naturalKey == firstKey },
                "the stored show must still hold its own key, not the incoming show's: \(rows.map(\.naturalKey).sorted())")
        #expect(rows.contains { $0.groupName == "Marlise (A New Golden Age Musical)" },
                "the stored show's title must survive: \(titles)")
    }

    // WHAT MUST NOT BREAK. The arm exists for #29: the same source listing and date, where the venue
    // TWEAKED the title between runs. A fix that made it strict would defeat its purpose and mint a
    // duplicate every time a venue added a subtitle, so the preservation case is asserted here beside
    // the fault, not left to the full suite to notice (L104).
    @Test func aTweakedTitleOnTheSameListingAndNightIsStillRecognised() throws {
        let ctx = try context()
        let first = stored(ctx, title: "Marlise")
        let firstKey = first.naturalKey
        try ctx.save()

        // The same show, the same page, the same night, with the subtitle the venue added.
        let incoming = ExtractedEvent(title: "Marlise (A New Golden Age Musical)",
                                      presenter: "The Players Theatre", venue: Self.venue,
                                      performanceDate: Self.night, sourceUrl: Self.page)
        _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                               today: "2026-08-20", sourceIds: ["theplayerstheatre-com"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                "a tweaked title on one listing and night is ONE show, not two: \(rows.map(\.groupName))")
        #expect(rows.first?.naturalKey != firstKey,
                "and the row is re-keyed onto the new title rather than left behind")
        #expect(rows.first?.groupName == "Marlise (A New Golden Age Musical)")
    }

    // THE PRECONDITION, so a verdict above cannot come from a fixture where the arm was never reachable
    // for some other reason (L159). Every field the arm keys on agrees, and the two titles are the ones
    // the app's own same-show test refuses, so nothing upstream of the arm should join them.
    @Test func theFixtureSatisfiesTheArmsPredicateExactly() {
        #expect(!GroupNameMatch.isSameShowTitle("Marlise (A New Golden Age Musical)",
                                                "Back to Shakespeare"))
        #expect(Prospect.makeNaturalKey(groupName: "Marlise (A New Golden Age Musical)",
                                        performanceDate: Self.night, venue: Self.venue)
                != Prospect.makeNaturalKey(groupName: "Back to Shakespeare",
                                           performanceDate: Self.night, venue: Self.venue),
                "the two shows must hold different natural keys, or the first arm answers and the fifth is never reached")
    }
}
