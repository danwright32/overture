import Testing
import Foundation
import SwiftData

// #1886: the identity key must stay anchored to the spelling THE SCOUT SENDS, not to whatever the card
// ends up displaying. Two shipped features rewrite a display field and deliberately leave the key alone
// for exactly that reason: #1274 (Dan renames a show, "naturalKey is left as-is ... so the scout's
// exact-key match keeps firing and no duplicate row is inserted") and #1846 (a merged card takes the room
// name Dan entered on the watchlist). Both promises were then undone one launch later, because
// NaturalKeyVenueMigration recomputed each row's expected key from the DISPLAY fields and re-keyed every
// row whose display no longer matched. The row that came back holding Dan's spelling was then invisible
// to the next scout, which arrives with the listing's spelling and computes the key it always computed.
//
// That is the failure #1886 was filed for. Its eight rows had already aged out of the live store by the
// time it was picked up, so the cause is pinned here instead, deterministically and off the live store:
// the venue rewrite landed 2026-07-30 (#1846, 832533d) and the guard went red the next day.
//
// The harm is the duplicate-card class (#1558, #1761): a key the next scout cannot compute is a key it
// cannot match, so it inserts a second card and strands Dan's keep, dismiss, or paid contact answer on
// the first one.
@MainActor
@Suite("A renamed card keeps the key the scout will send (#1886)")
struct MergedRoomNameKeepsTheScoutsKeyTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self, WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func watch(_ ctx: ModelContext, id: String, orgName: String) {
        ctx.insert(WatchedSource(sourceId: id, orgName: orgName, kind: .html))
        try? ctx.save()
    }

    // Inserted with the REAL key the scout would have minted for it, not a stand-in, because the whole
    // question here is whether that key survives.
    @discardableResult
    private func insert(_ ctx: ModelContext, _ group: String, date: String?, venue: String,
                        ingestedAt: TimeInterval = 1_000) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: group,
                                                             performanceDate: date, venue: venue),
                         groupName: group,
                         discipline: "music", venue: venue, performanceDate: date,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new,
                         ingestedAt: Date(timeIntervalSince1970: ingestedAt))
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func all(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // The live shape, from the pair #1761 and #1846 were measured on: the listing spells the room its own
    // way, Dan entered a different spelling when he started watching it, and the merge puts his spelling
    // on the surviving card. The two fold to DIFFERENT keys, which is asserted rather than assumed, or
    // this test would pass for the wrong reason.
    private let listingSpelling = "Jalopy Theater, 315 Columbia Street, Brooklyn, New York"
    private let dansSpelling = "Jalopy Theatre"
    private let title = "Roots n' Ruckus"
    private let night = "2026-08-05"

    private var scoutKey: String {
        Prospect.makeNaturalKey(groupName: title, performanceDate: night, venue: listingSpelling)
    }

    @Test func theTwoSpellingsReallyDoFoldToDifferentKeys() {
        let dansKey = Prospect.makeNaturalKey(groupName: title, performanceDate: night, venue: dansSpelling)
        #expect(scoutKey != dansKey, "the fixture is only meaningful while these two spellings disagree")
    }

    // The merge itself. It rewrites the surviving card's venue to Dan's spelling on purpose, and the key
    // is deliberately left alone so the next scout still finds the row.
    @Test func theMergeRenamesTheCardWithoutMovingItsKey() throws {
        let ctx = try context()
        watch(ctx, id: "jalopytheatre-netlify-app", orgName: dansSpelling)
        insert(ctx, title, date: night, venue: listingSpelling, ingestedAt: 1_000)
        insert(ctx, title, date: night, venue: dansSpelling, ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        #expect(survivor.venue == dansSpelling, "the card names the room Dan entered")
        #expect(survivor.naturalKey == scoutKey, "and is still found by the key the scout sends")
    }

    // The launch that follows, which is where #1886's eight rows were made. Every pass in
    // LaunchMigrations runs on every launch, and the re-key pass runs BEFORE the merge, so a card the
    // merge renamed meets the re-key pass at the NEXT launch. It must leave that card's key where the
    // scout can still find it.
    @Test func theNextLaunchLeavesTheRenamedCardFindableByTheScout() throws {
        let ctx = try context()
        watch(ctx, id: "jalopytheatre-netlify-app", orgName: dansSpelling)
        insert(ctx, title, date: night, venue: listingSpelling, ingestedAt: 1_000)
        insert(ctx, title, date: night, venue: dansSpelling, ingestedAt: 2_000)
        SameNightTitleVariantMerge.run(in: ctx)
        try? ctx.save()

        NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        #expect(survivor.naturalKey == scoutKey,
                "the next scout computes this key from the listing's own spelling; a row that no longer carries it is a row the scout cannot match, so it inserts a second card")
    }

    // Anchoring the check to the scout's spelling must not turn it into a check of a value against
    // itself. A row nothing has ever renamed is still judged on its own venue, so a fold that genuinely
    // moves under the store still shows up as drift and still gets re-keyed. Without this, the fix for
    // #1886 would read as a fix while quietly retiring the guard that found it.
    @Test func aFoldThatGenuinelyMovesIsStillDrift() throws {
        let ctx = try context()
        let row = insert(ctx, title, date: night, venue: listingSpelling)
        #expect(row.scoutVenue == nil, "nothing has renamed this row, so it speaks for itself")

        // What a widened fold leaves behind: a stored key minted under the OLD rules.
        row.naturalKey = "roots n ruckus|2026-08-05|jalopy theater 315 columbia street"
        try? ctx.save()
        #expect(row.scoutAnchoredNaturalKey != row.naturalKey, "this is drift and must be seen as drift")

        NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(try #require(all(ctx).first).naturalKey == scoutKey, "and the launch pass still re-keys it")
    }

    // The merge runs on EVERY launch, not once. On the second run the survivor's venue is already Dan's
    // spelling, so a pass that overwrote the stored scout spelling here would lose the listing's own word
    // for the room on the second launch and re-key the row exactly as before, one day later.
    @Test func asecondLaunchDoesNotOverwriteTheScoutsSpellingWithDans() throws {
        let ctx = try context()
        watch(ctx, id: "jalopytheatre-netlify-app", orgName: dansSpelling)
        insert(ctx, title, date: night, venue: listingSpelling, ingestedAt: 1_000)
        insert(ctx, title, date: night, venue: dansSpelling, ingestedAt: 2_000)

        SameNightTitleVariantMerge.run(in: ctx)
        NaturalKeyVenueMigration.run(in: ctx)
        SameNightTitleVariantMerge.run(in: ctx)
        NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let survivor = try #require(all(ctx).first)
        #expect(survivor.scoutVenue == listingSpelling)
        #expect(survivor.venue == dansSpelling)
        #expect(survivor.naturalKey == scoutKey)
    }

    // The same promise on the title half (#1274). Dan's rename is display-only and the key stays
    // scout-name-derived, so the re-key pass must not drag the key onto his name either.
    @Test func theNextLaunchLeavesADanRenamedShowFindableByTheScout() throws {
        let ctx = try context()
        let scoutName = "MUSIC AT ST MARYS: EVENSONG"
        let row = insert(ctx, scoutName, date: night, venue: listingSpelling)
        let mintedKey = row.naturalKey

        row.scoutGroupName = scoutName
        row.groupName = "Evensong at St Mary the Virgin"
        row.groupNameOverriddenByDan = true
        try? ctx.save()

        NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        let stored = try #require(all(ctx).first)
        #expect(stored.naturalKey == mintedKey,
                "#1274 promises the rename does not move the key, so the scout's exact-key match keeps firing")
    }
}
