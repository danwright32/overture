import Testing
import Foundation
import SwiftData

// #3495: a row the scout MINTS must be anchored to the spelling the scout sent, exactly as a row the
// scout RE-INGESTS is. `ScoutService.apply` (the update path) sets both anchor fields on every re-ingest;
// `ScoutService.make` (the insert path) set neither, so every freshly minted row started with no anchor
// and only acquired one if it was ever re-ingested.
//
// Why the fields are not decoration. #1886 added them so the natural key could be anchored to what the
// SCOUT sends rather than to whatever the card ends up DISPLAYING, because two shipped features rewrite a
// display field on purpose: #1274 (Dan renames a show) and #1846 (a merged card takes the room name Dan
// entered on the watchlist). `Prospect.scoutAnchoredNaturalKey` is `scoutGroupName ?? groupName` and
// `scoutVenue ?? venue`, and `NaturalKeyVenueMigration` re-keys every row from it at launch. A row with no
// anchor is therefore re-keyed from its DISPLAY fields, which is the precise thing #1886 exists to prevent.
//
// Measured on the live store when #3495 was filed: 9 of 9 rows first seen that day were missing BOTH
// fields, against 9 of 381 rows ingested that day, which is the signature of a field written on one path
// and not the other. It is invisible from the writer alone, because every row that has ever been
// re-ingested looks correct (L389: a writer that only fills forward leaves the population it cannot reach
// permanently unfilled, and that population is the NEWEST rows).
//
// This drives the real ingest rather than calling `make` (which is private), because the claim is about
// what the PIPELINE stores, not about one function.
@MainActor
@Suite("A minted row is anchored to what the scout sent (#3495)")
struct ScoutAnchorOnInsertTests {

    private func container() throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      isStoredInMemoryOnly: true)])
    }

    private func ingest(_ events: [ExtractedEvent], into ctx: ModelContext) {
        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                               today: "2026-09-10", sourceIds: ["a-source"], into: ctx)
    }

    // THE CLAIM. A row that has only ever been INSERTED carries both anchors.
    @Test func aFreshlyMintedRowCarriesBothAnchorFields() throws {
        let ctx = ModelContext(try container())
        ingest([ExtractedEvent(title: "The Gilded Hour", presenter: "Marchand Company",
                               venue: "Weill Recital Hall", performanceDate: "2026-11-04",
                               sourceUrl: "https://example.test/a")], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, "the fixture must insert exactly one row, got \(rows.count)")
        let row = try #require(rows.first)
        #expect(row.scoutGroupName == "The Gilded Hour",
                "a minted row has no title anchor, so a later rename re-keys it from its display name (#3495)")
        #expect(row.scoutVenue == "Weill Recital Hall",
                "a minted row has no venue anchor, so a room rename re-keys it from its display name (#3495)")
    }

    // The invariant the fix is really for, and the one a field check alone does not show: after the display
    // name is rewritten the way #1274 rewrites it, the anchored key must still name what the scout sent.
    @Test func renamingTheCardDoesNotMoveTheAnchoredKey() throws {
        let ctx = ModelContext(try container())
        ingest([ExtractedEvent(title: "The Gilded Hour", presenter: "Marchand Company",
                               venue: "Weill Recital Hall", performanceDate: "2026-11-04",
                               sourceUrl: "https://example.test/a")], into: ctx)
        try ctx.save()
        let row = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        let anchoredBefore = row.scoutAnchoredNaturalKey

        row.groupName = "Gilded Hour, The (renamed by Dan)"
        try ctx.save()

        #expect(row.scoutAnchoredNaturalKey == anchoredBefore,
                "the anchored key followed the display name, which is what the anchor exists to prevent (#3495, #1886)")
    }

    // The control. A re-ingested row was ALREADY correct before this change, so a test that passed on both
    // paths would prove nothing about which path was broken (L159).
    @Test func aReIngestedRowWasAlreadyAnchored() throws {
        let ctx = ModelContext(try container())
        let event = ExtractedEvent(title: "The Gilded Hour", presenter: "Marchand Company",
                                   venue: "Weill Recital Hall", performanceDate: "2026-11-04",
                                   sourceUrl: "https://example.test/a")
        ingest([event], into: ctx)
        try ctx.save()
        ingest([event], into: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(rows.count == 1, "the second ingest must UPDATE, not insert, got \(rows.count) rows")
        #expect(rows.first?.scoutGroupName == "The Gilded Hour")
    }
}
