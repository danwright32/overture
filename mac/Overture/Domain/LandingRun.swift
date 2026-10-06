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
//
// #4335 (A6, the first part) extends it as A7 planned: every landing of either entry point now records a row
// when its synchronous landing block STARTS (after the entry flush and the last await, so the read phase
// stays clean), with `landedAt` nil, carried to disk by the landing's first save, and stamps `landedAt` in
// its closing save. A row with `landedAt` nil is a landing that started and did not finish.
@Model
final class LandingRun {
    var runIdentity: String
    var landedAt: Date?
    // #4335: the run's landing sequence, which the next landing's sequence is minted above (`highestSequence`),
    // so a sequence a landing saved can never be handed out again. Defaulted, so A7's rows migrate as zero.
    var sequence: Int = 0
    // #4335: which landing this was (`LandingSingleFlight.EntryPoint`'s raw value). Empty on A7's rows.
    var entryPointRaw: String = ""
    // #4335: the landing's own `now`, the time it stamps its rows with (L37). nil on A7's rows.
    var startedAt: Date?
    // #4335 (A6, the recovery): how many times an interrupted landing has been STARTED again by the recovery
    // (`LandingRecovery`), counted and saved BEFORE each attempt, so an attempt that ends the process (a SQLite
    // trigger, measured by #4327 step 0.8) still counts and the cap of `LandingRecovery.attemptCap` is reached
    // rather than retried for ever. 0 on every landing that was never interrupted.
    var attemptCount: Int = 0
    // #4335: when the recovery finished this landing, nil while it has not and on every landing that finished
    // by itself. With `startedAt`, the delay between the two is what an interrupted landing cost.
    var recoveredAt: Date?
    // #4338 (A10): how many of this landing's entry flushes (`ScoutService.flushBeforeLanding`, one in its read
    // phase and one under the token) found edits pending and saved them, 0 to 2, added to on every attempt of
    // the same run. Kept here rather than on the run's outcome because the rows are never pruned, so the rate
    // over time is readable: `scripts/landing-flush-rate.sh` is its reader. OPTIONAL, and that is the marker:
    // every landing that reaches its landing block under a build that writes it sets it, to 0 or more, so nil
    // says "no count recorded" (a row from before #4338, or one the recovery made for a landing that never
    // reached its first save), which the reader leaves out rather than reading as a landing that saved nothing.
    var entryFlushSaves: Int? = nil

    init(runIdentity: String, landedAt: Date?, sequence: Int = 0,
         entryPoint: LandingSingleFlight.EntryPoint? = nil, startedAt: Date? = nil) {
        self.runIdentity = runIdentity
        self.landedAt = landedAt
        self.sequence = sequence
        self.entryPointRaw = entryPoint?.rawValue ?? ""
        self.startedAt = startedAt
    }

    // #4335: the record of the landing with this identity and sequence, the newest first if a failed read ever
    // left two (`begin` says when that can happen). nil when the landing never reached its first save. Throws on a
    // failed read, which is never "no record" (L215).
    static func record(_ identity: String, sequence: Int, in context: ModelContext) throws -> LandingRun? {
        let rows = FetchDescriptor<LandingRun>(predicate: #Predicate { $0.runIdentity == identity && $0.sequence == sequence })
        return try context.fetch(rows).sorted { ($0.landedAt ?? .distantPast) > ($1.landedAt ?? .distantPast) }.first
    }

    // #4335: the highest sequence any landing has recorded, the store's half of the floor a new sequence is
    // minted above (the journal names are the other half). One sorted fetch of one row. Rows are never
    // pruned, so this can only rise; any future retention must keep the highest. Throws on a failed read.
    static func highestSequence(in context: ModelContext) throws -> Int {
        var top = FetchDescriptor<LandingRun>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        top.fetchLimit = 1
        return try context.fetch(top).first?.sequence ?? 0
    }

    // #4335: the row a landing records itself on. A kept copy offered again lands as the SAME run (same
    // identity, same sequence), so it reuses the row an earlier attempt saved rather than adding a second
    // row with one sequence. A read that fails inserts a new row, since refusing would lose the landing to a
    // read nothing else needed; the two rows then share a sequence, which the recovery refuses by name.
    static func begin(runIdentity: String, sequence: Int, entryPoint: LandingSingleFlight.EntryPoint,
                      startedAt: Date, in context: ModelContext) -> LandingRun {
        let earlier = FetchDescriptor<LandingRun>(
            predicate: #Predicate { $0.runIdentity == runIdentity && $0.sequence == sequence && $0.landedAt == nil })
        if let row = (try? context.fetch(earlier))?.first { return row }
        let row = LandingRun(runIdentity: runIdentity, landedAt: nil, sequence: sequence,
                             entryPoint: entryPoint, startedAt: startedAt)
        context.insert(row)
        return row
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
