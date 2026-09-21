import Testing
import Foundation
import SwiftData

// #4056: the production token poison map is built once per INCOMING LISTING, so it can only ever see
// the stored rows plus the one listing being processed.
//
// The cost of that is what the issue is about. The CORRECTNESS consequence is what this suite pins, and
// it is the reason the fix is "once per batch, over every incoming event" rather than the hoist the
// issue first proposed (see its 2026-09-21 comment): a second listing arriving in the SAME sweep that
// would poison the token is invisible while the first is judged.
//
// The poison rule exists because a venue stamping one token across its whole season would otherwise fuse
// the season into one card. A map that cannot see the rest of the batch is blind to exactly that venue
// on the sweep where it first does it.
@MainActor
@Suite("The production token poison map is built over the whole batch (#4056)")
struct BatchWidePoisonMapTests {

    private static let venue = "The Green Room 42"
    private static let token = "https://thegreenroom42.venuetix.com/showdetails/seasonToken"

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, title: String, night: String) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                             venue: Self.venue),
                         groupName: title, discipline: "theatre", venue: Self.venue,
                         performanceDate: night, sourceListingURL: "\(Self.token)/\(night)",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private func event(_ title: String, _ night: String) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "The Green Room 42", venue: Self.venue,
                       performanceDate: night, sourceUrl: "\(Self.token)/\(night)")
    }

    // THE CASE, and the ORDER is the whole of it.
    //
    // One stored row under a token, and a sweep carrying two listings that share it under DIFFERENT
    // titles. The token is a season stamp, so it must join nothing, whichever order the sweep happens to
    // present them in.
    //
    // Judged per listing, the answer depends on arrival order. The poisoning listing here plays LATER
    // (2026-10-29) than the one that would re-key (2026-10-12), so the re-key is decided first, against a
    // map holding only itself and the stored row, both under one title. The token reads as clean and the
    // join happens. The listing that would have revealed it is processed afterwards, by which time the
    // decision is made and cannot be taken back.
    //
    // Written this way round DELIBERATELY. The opposite order passes today for a reason that has nothing
    // to do with the rule: the poisoning listing simply happens to be seen first, so a test built that way
    // is green against the defect (L159).
    @Test func alaterListingInTheSameSweepStillPoisonsTheToken() throws {
        let ctx = try context()
        stored(ctx, title: "First Show", night: "2026-10-11")
        try ctx.save()

        _ = ScoutService.apply(events: [event("First Show", "2026-10-12"),
                                        event("Second Show", "2026-10-29")],
                               clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["thegreenroom42"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 3,
                Comment(rawValue: "a season token joined rows it must not: expected 3 separate rows, got "
                        + "\(rows.count) (\(rows.map(\.groupName).sorted()))"))
    }

    // The SAME store and the SAME three shows, presented in the other order, which is green today. Kept
    // so the pair states the property that matters: the answer must not depend on which night the venue
    // happens to list first (L455, L419).
    @Test func theanswerIsTheSameWhicheverOrderTheSweepPresentsThem() throws {
        let ctx = try context()
        stored(ctx, title: "First Show", night: "2026-10-11")
        try ctx.save()

        _ = ScoutService.apply(events: [event("Second Show", "2026-10-12"),
                                        event("First Show", "2026-10-29")],
                               clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["thegreenroom42"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 3,
                Comment(rawValue: "expected 3 separate rows, got \(rows.count)"))
    }

    // The control, and it is what stops the fix above being "poison everything". One title across the
    // whole batch is the ORDINARY shape of a multi night run, and joining it is exactly what the arm is
    // for (L159, L104).
    @Test func onetitleAcrossTheBatchStillJoins() throws {
        let ctx = try context()
        stored(ctx, title: "First Show", night: "2026-10-11")
        try ctx.save()

        _ = ScoutService.apply(events: [event("First Show", "2026-10-29")],
                               clients: [], history: [], blocked: .empty,
                               today: "2026-10-01", sourceIds: ["thegreenroom42"], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1,
                Comment(rawValue: "the token arm stopped joining two nights of one production, leaving "
                        + "\(rows.count) rows"))
    }
}
