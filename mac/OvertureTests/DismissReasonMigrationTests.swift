import Testing
import Foundation
import SwiftData

// #940: 'Day doesn't work' is folded into 'Date conflict' (they behaved identically). Any prospect Dan
// already dismissed with the old reason must be rewritten, or the Archive would show a reason string that
// no longer decodes to anything. A one-shot, idempotent launch pass, like the other LaunchMigrations.
@MainActor
@Suite("Dismiss-reason migration (#940)")
struct DismissReasonMigrationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func dismissed(_ ctx: ModelContext, key: String, reasonRaw: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-11-18", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .dismissed)
        p.dismissReasonRaw = reasonRaw
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func theOldReasonIsRewrittenToDateConflict() throws {
        let ctx = try context()
        let old = dismissed(ctx, key: "a", reasonRaw: "day_doesnt_work")
        let kept = dismissed(ctx, key: "b", reasonRaw: "date_conflict")
        let other = dismissed(ctx, key: "c", reasonRaw: "not_interested")

        let changed = DismissReasonMigration.run(in: ctx)

        #expect(changed == 1)
        #expect(old.dismissReasonRaw == "date_conflict")     // migrated
        #expect(kept.dismissReasonRaw == "date_conflict")    // untouched
        #expect(other.dismissReasonRaw == "not_interested")  // untouched
    }

    @Test func itIsIdempotent() throws {
        let ctx = try context()
        _ = dismissed(ctx, key: "a", reasonRaw: "day_doesnt_work")
        _ = DismissReasonMigration.run(in: ctx)
        #expect(DismissReasonMigration.run(in: ctx) == 0)    // nothing left to change
    }
}
