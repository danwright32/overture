import Foundation
import SwiftData

// #4336 (A7): the store's record that a landing of one run's results finished, so the same results are
// refused as "already landed" rather than landed a second time.
//
// The narrowest record A7 needs, built so A6 (#4335, landing recovery) EXTENDS it rather than replacing it:
//
//   `runIdentity` is the run identity A6 defines. For an ingest it is the results file's content hash
//   (`PendingScoutIngests.contentHash`), the same key the kept copies are filed under; A6 adds runScout's
//   sweep id under the same column.
//   `landedAt` is nil until the landing reaches its terminal landed state. A7 inserts a row only at that
//   point, in the landing's closing save, so every row it writes is landed. A6 inserts its row when the
//   landing STARTS (nil here) and stamps it at the end, and adds its own columns beside these two
//   (sequence, entry point, step stamps, recovery time and attempts).
//
// Independent of every other model, with no relationship to any, so the migration is purely additive
// (rehearsed in LandingRunMigrationDryRunTests). Rows are never pruned (A6's sequence floor reads them).
@Model
final class LandingRun {
    var runIdentity: String
    var landedAt: Date?

    init(runIdentity: String, landedAt: Date?) {
        self.runIdentity = runIdentity
        self.landedAt = landedAt
    }

    // When the results with this identity FIRST landed, or nil when no landing of them has finished. The
    // earliest, because that is the landing every later one repeats, and because nothing rests on a
    // uniqueness constraint (SwiftData's `.unique` is an upsert): two rows for one identity still answer
    // with the first. One fetch of one row. A failed fetch THROWS, so a store that cannot answer is never
    // read as "never landed" (L215).
    static func landedAt(_ identity: String, in context: ModelContext) throws -> Date? {
        var first = FetchDescriptor<LandingRun>(
            predicate: #Predicate { $0.runIdentity == identity && $0.landedAt != nil },
            sortBy: [SortDescriptor(\.landedAt)])
        first.fetchLimit = 1
        return try context.fetch(first).first?.landedAt
    }
}
