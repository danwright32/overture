import Testing
import Foundation
import SwiftData

// #3615. A show whose NAME grows is stored twice, under the old key and the new.
//
// Measured on the live store 2026-09-07, four rows, two shows:
//
//     ZGROUPNAME                                        ZSCOUTGROUPNAME              ZNATURALKEY
//     Bar Harbor Music Festival 60th Anniversary Gala   Bar Harbor Music Festival    bar harbor music festival|...
//     Bar Harbor Music Festival 60th Anniversary Gala   (none)                       bar harbor music festival 60th anniversary gala|...
//
// `scoutAnchoredNaturalKey` reads `scoutGroupName ?? groupName`, and that pin exists for a good reason
// (#1886/#1274: a row Dan RENAMES must keep the key the scout can still find it by). What it does not
// survive is the SOURCE renaming its own show: the pin then holds a name the source no longer publishes,
// the next scout computes a key from the new one, matches nothing, and inserts a second row. The row is
// unreachable by the scout from then on.
//
// `NaturalKeyVenueMigration` groups by that anchored key, so the two rows land in different groups and it
// correctly does nothing. The two live-store suites group by what is ON SCREEN (`groupName|date|venue`),
// which now matches across the pair, which is why they go red about a pass that is behaving.
//
// THE MERGE ITSELF IS UNCHANGED. Same `mustDefer`, same survivor ladder, same refusal to reconcile two
// histories blind. What changes is only which rows are seen to be one show.
@MainActor
@Suite("A show whose name grows is not two shows (#3615)")
struct AShowWhoseNameGrowsTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, key: String, groupName: String, scoutGroupName: String?,
                     ingestedAt: Date, fitScore: Int = 5, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: groupName, discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2027-10-22",
                         sourceListingURL: nil, priorRelationship: "none", production: "unknown",
                         profile: "strong", coverage: "likely_uncovered", fitScore: fitScore,
                         tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        p.scoutGroupName = scoutGroupName
        p.scoutVenue = "Weill Recital Hall"
        p.ingestedAt = ingestedAt
        p.sentAt = sentAt
        try? ctx.save()
        return p
    }

    private let older = Date(timeIntervalSinceReferenceDate: 807_470_537)
    private let newer = Date(timeIntervalSinceReferenceDate: 810_481_843)

    // The measured shape. One show on screen, two rows in the store, and the pass used to leave both.
    @Test func theOldKeyAndTheNewCollapseOntoOneRow() throws {
        let ctx = try context()
        let pinned = row(ctx, key: "jinhyung park|2027-10-22|weill recital hall",
                         groupName: "Jinhyung Park, Piano", scoutGroupName: "Jinhyung Park",
                         ingestedAt: older, fitScore: 5)
        let fresh = row(ctx, key: "jinhyung park piano|2027-10-22|weill recital hall",
                        groupName: "Jinhyung Park, Piano", scoutGroupName: nil,
                        ingestedAt: newer, fitScore: 5)

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try ctx.save()

        #expect(summary.duplicatesDeleted == 1)
        let left = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(left.count == 1)
        // The FRESHEST survives, which is the pass's own tie-break among pristine rows, and here it is
        // also the only one the scout can still find: its key is the one computed from the name the
        // source publishes today. Keeping the pinned row would leave a card no future scout can reach.
        #expect(left.first?.naturalKey == fresh.naturalKey)
        #expect(pinned.isDeleted || !left.contains { $0.naturalKey.contains("jinhyung park|") })
    }

    // Two rows that are the same show and carry NO shared display identity are not this defect and must
    // not be touched: a different show on the same night in the same room is two rows on purpose.
    @Test func twoDifferentShowsInOneRoomAreLeftAlone() throws {
        let ctx = try context()
        row(ctx, key: "kestrel quartet|2027-10-22|weill recital hall", groupName: "Kestrel Quartet",
            scoutGroupName: nil, ingestedAt: older)
        row(ctx, key: "rowan trio|2027-10-22|weill recital hall", groupName: "Rowan Trio",
            scoutGroupName: nil, ingestedAt: newer)

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        #expect(summary.duplicatesDeleted == 0)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 2)
    }

    // The refusal is unchanged and still governs: two rows that EACH carry a real outreach record are
    // never merged blind, whichever grouping found them. Merging two histories is Dan's call, not a
    // migration's, and that rule may not be weakened by widening what counts as one show.
    @Test func twoRowsCarryingHistoryAreStillDeferredNotMerged() throws {
        let ctx = try context()
        row(ctx, key: "jinhyung park|2027-10-22|weill recital hall",
            groupName: "Jinhyung Park, Piano", scoutGroupName: "Jinhyung Park",
            ingestedAt: older, sentAt: older)
        row(ctx, key: "jinhyung park piano|2027-10-22|weill recital hall",
            groupName: "Jinhyung Park, Piano", scoutGroupName: nil,
            ingestedAt: newer, sentAt: newer)

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        try ctx.save()

        #expect(summary.duplicatesDeleted == 0)
        #expect(summary.conflictsDeferred == 1)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 2)
    }

    // Idempotent, which this pass must stay: it runs on every launch, and a second run over a store it
    // has already settled has to change nothing and delete nothing.
    @Test func asecondRunOverASettledStoreChangesNothing() throws {
        let ctx = try context()
        row(ctx, key: "jinhyung park|2027-10-22|weill recital hall",
            groupName: "Jinhyung Park, Piano", scoutGroupName: "Jinhyung Park", ingestedAt: older)
        row(ctx, key: "jinhyung park piano|2027-10-22|weill recital hall",
            groupName: "Jinhyung Park, Piano", scoutGroupName: nil, ingestedAt: newer)

        _ = NaturalKeyVenueMigration.run(in: ctx)
        try ctx.save()
        let second = NaturalKeyVenueMigration.run(in: ctx)
        try ctx.save()

        #expect(second == NaturalKeyVenueMigration.Summary())
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 1)
    }

    // A row Dan RENAMED is the case the pin exists for, and widening the grouping must not undo it: his
    // spelling and the source's are one show, they already share a key, and there is nothing to merge.
    @Test func arowDanRenamedIsUntouched() throws {
        let ctx = try context()
        row(ctx, key: "jinhyung park|2027-10-22|weill recital hall",
            groupName: "Jin's Recital", scoutGroupName: "Jinhyung Park", ingestedAt: older)

        let summary = NaturalKeyVenueMigration.run(in: ctx)
        #expect(summary == NaturalKeyVenueMigration.Summary())
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 1)
    }
}
