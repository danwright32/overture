import Testing
import Foundation
import SwiftData
@testable import Overture

// #1064: existing prospects carry their OLD, unfolded natural keys, so a fresh scout of a differently
// spelled venue would not dedupe against them. NaturalKeyVenueMigration re-keys stored rows with the new
// venue normalization and reconciles the duplicates that fold together, merging only provably-empty
// duplicates and deferring (never blindly merging) a collision where two rows both carry outreach history.
@MainActor
@Suite("Natural-key venue re-keying migration (#1064)")
struct NaturalKeyVenueMigrationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // Inserts a prospect with an explicitly chosen (possibly legacy) stored key, so a test can reproduce a
    // store where the same show sits twice under two different venue spellings.
    @discardableResult
    private func insert(_ ctx: ModelContext, key: String, group: String, date: String, venue: String,
                        ingestedAt: Date = Date(), configure: (Prospect) -> Void = { _ in }) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new, ingestedAt: ingestedAt)
        configure(p)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func allProspects(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    private func foldedKey(_ group: String, _ date: String, _ venue: String) -> String {
        Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
    }

    // The Cutting Room pair, both untriaged: they collapse to one row, keyed by the folded key, and the
    // unrelated show is left completely alone.
    @Test func twoPristineDuplicatesCollapseToOneAndOthersAreUntouched() throws {
        let ctx = try context()
        let group = "GATA Jazz Trio", date = "2026-07-18"
        let folded = foldedKey(group, date, "The Cutting Room")

        insert(ctx, key: folded, group: group, date: date, venue: "The Cutting Room",
               ingestedAt: Date(timeIntervalSince1970: 1_000))
        insert(ctx, key: "legacy-address-key", group: group, date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 2_000))
        // An unrelated show that must never be touched.
        let otherKey = foldedKey("Some Other Act", "2026-08-15", "Zankel Hall")
        insert(ctx, key: otherKey, group: "Some Other Act", date: "2026-08-15", venue: "Zankel Hall")

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        #expect(summary.conflictsDeferred == 0)
        let all = allProspects(ctx)
        #expect(all.count == 2)   // the duplicate pair became one, plus the unrelated show
        #expect(all.filter { $0.naturalKey == folded }.count == 1)
        #expect(all.contains { $0.naturalKey == otherKey })   // unrelated show survived untouched
    }

    // When exactly one of the colliding rows carries outreach history, that row survives (with its
    // history), the pristine duplicate is deleted, and the survivor takes the folded key.
    @Test func theRowWithHistorySurvivesAndKeepsItsHistory() throws {
        let ctx = try context()
        let group = "Love Is Live", date = "2026-08-01"
        let folded = foldedKey(group, date, "The Players Theatre")

        // The pristine bare row happens to already hold the folded key.
        insert(ctx, key: folded, group: group, date: date, venue: "The Players Theatre")
        // The address-spelled row was actually contacted: it must be the survivor.
        let contacted = insert(ctx, key: "legacy-address-key", group: group, date: date,
                               venue: "The Players Theatre, 115 MacDougal Street, New York, NY") { p in
            p.status = .contacted
            p.sentAt = Date(timeIntervalSince1970: 5_000)
            p.gmailMessageId = "msg-123"
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        let all = allProspects(ctx)
        #expect(all.count == 1)
        let survivor = all[0]
        #expect(survivor === contacted)              // the contacted row won
        #expect(survivor.sentAt != nil)              // its history is intact
        #expect(survivor.gmailMessageId == "msg-123")
        #expect(survivor.naturalKey == folded)       // and it now carries the folded key
    }

    // When TWO colliding rows each carry history, the migration refuses to merge blind: both rows stay,
    // with their original keys, and the conflict is reported for Dan to reconcile.
    @Test func twoRowsBothCarryingHistoryAreDeferredNotMerged() throws {
        let ctx = try context()
        let group = "Off the Chart", date = "2026-07-22"

        let a = insert(ctx, key: "legacy-key-a", group: group, date: date, venue: "The Cutting Room") { p in
            p.status = .contacted
            p.sentAt = Date(timeIntervalSince1970: 3_000)
        }
        let b = insert(ctx, key: "legacy-key-b", group: group, date: date,
                       venue: "The Cutting Room, 44 East 32nd Street, New York, NY") { p in
            p.status = .dismissed
            p.dismissReasonRaw = DismissReason.notInterested.rawValue
        }

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.conflictsDeferred == 1)
        #expect(summary.duplicatesDeleted == 0)
        let all = allProspects(ctx)
        #expect(all.count == 2)                       // nothing dropped
        #expect(a.naturalKey == "legacy-key-a")       // keys left exactly as they were
        #expect(b.naturalKey == "legacy-key-b")
    }

    // Running twice is a no-op the second time: after the first pass every row already holds its folded
    // key, so nothing is re-keyed or deleted again.
    @Test func runningTwiceIsIdempotent() throws {
        let ctx = try context()
        let group = "STEVEN MAGLIO & HIS BIG BAND ORCHESTRA", date = "2026-07-19"
        let folded = foldedKey(group, date, "The Cutting Room")
        insert(ctx, key: folded, group: group, date: date, venue: "The Cutting Room")
        insert(ctx, key: "legacy-address-key", group: group, date: date,
               venue: "The Cutting Room, 44 East 32nd Street, New York, NY")

        _ = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()
        let afterFirst = allProspects(ctx).count

        let second = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(second == NaturalKeyVenueMigration.Summary())   // all zeros
        #expect(allProspects(ctx).count == afterFirst)          // nothing removed on the second pass
    }

    // A lone row that carries an embedded address (no duplicate twin) is simply re-keyed to its folded
    // form, so a future scout of the bare spelling dedupes against it. Nothing is deleted.
    // #1498: the shape this migration could not see until the key stopped carrying the trailing location.
    // Measured on the live store 2026-07-25: 29 pairs exactly like this one, every row untriaged with no
    // recipients and nothing sent, so Dan was triaging the same night twice. The two Jalopy spellings are
    // the live case verbatim.
    @Test func aVenueWithAndWithoutItsTrailingLocationCollapsesToOneShow() throws {
        let ctx = try context()
        let group = "Bruce Molsky & Darol Anger", date = "2026-07-25"
        let folded = foldedKey(group, date, "Jalopy Theatre")

        let older = insert(ctx, key: "old-bare", group: group, date: date, venue: "Jalopy Theatre",
                           ingestedAt: Date(timeIntervalSince1970: 100))
        insert(ctx, key: "old-with-location", group: group, date: date,
               venue: "Jalopy Theatre, Red Hook, Brooklyn, NY",
               ingestedAt: Date(timeIntervalSince1970: 200))

        let summary = NaturalKeyVenueMigration.run(in: ctx)

        let remaining = allProspects(ctx)
        #expect(remaining.count == 1, "one show must be one row")
        #expect(remaining.first === older, "the earliest-ingested row survives when both are pristine")
        #expect(remaining.first?.naturalKey == folded)
        #expect(summary.duplicatesDeleted == 1)
    }

    // The parent-building spelling from the same audit (eight Carnegie shows). Worth its own case because
    // NEITHER stored key equals the new folded key, so without this pass a fresh scout would have added a
    // THIRD row rather than converging on one of the two.
    @Test func aParentBuildingSpellingCollapsesTooAndLeavesNoStaleKey() throws {
        let ctx = try context()
        let group = "A Gospel of Gratitude", date = "2026-11-28"
        let venue = "Stern Auditorium/Perelman Stage"
        let folded = foldedKey(group, date, venue)

        insert(ctx, key: "old-long", group: group, date: date,
               venue: "\(venue), Carnegie Hall, New York, NY",
               ingestedAt: Date(timeIntervalSince1970: 100))
        insert(ctx, key: "old-short", group: group, date: date, venue: "\(venue), Carnegie Hall",
               ingestedAt: Date(timeIntervalSince1970: 200))

        NaturalKeyVenueMigration.run(in: ctx)

        let remaining = allProspects(ctx)
        #expect(remaining.count == 1)
        #expect(remaining.first?.naturalKey == folded,
                "the survivor must carry the folded key, or the next scout adds a third row")
    }

    @Test func aLoneAddressRowIsRekeyedNotDeleted() throws {
        let ctx = try context()
        let group = "Solo Recital", date = "2026-10-10"
        insert(ctx, key: "legacy-address-key", group: group, date: date,
               venue: "The Players Theatre, 115 MacDougal Street, New York, NY")

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try? ctx.save()

        #expect(summary.rekeyed == 1)
        #expect(summary.duplicatesDeleted == 0)
        let all = allProspects(ctx)
        #expect(all.count == 1)
        #expect(all[0].naturalKey == foldedKey(group, date, "The Players Theatre"))
    }
}
