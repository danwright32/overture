import Foundation
import SwiftData

// #16: stamp `firstSeenAt` on every prospect that predates the field, so the funnel's opening node can
// count the shows already in the store rather than starting from empty on the day this shipped.
//
// The source is each row's current `ingestedAt`. For a show never re-scouted since it was found, that IS
// its first sighting. For one the scout has read again, `ingestedAt` has walked forward, so the stamp is
// an UPPER BOUND: no later than this. It never invents a date nothing observed, and it can only ever be
// too late, never too early, so a period report under-counts rather than over-counts. Dan chose this over
// leaving the rows blank (2026-07-23), knowing the pre-ship months read as approximate.
//
// Idempotent, and that property is load-bearing rather than incidental: this runs on EVERY launch, and
// `ingestedAt` moves between launches, so a pass that re-stamped an already-stamped row would drag the
// first sighting forward one launch at a time until every show looked like it was found yesterday. The
// `firstSeenAt == nil` guard is the whole defence.
enum FirstSeenBackfill {
    // Returns how many rows it stamped, so a caller can report what it actually did.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let unstamped = FetchDescriptor<Prospect>(predicate: #Predicate { $0.firstSeenAt == nil })
        guard let rows = try? context.fetch(unstamped) else { return 0 }
        for p in rows {
            p.firstSeenAt = p.ingestedAt
        }
        return rows.count
    }
}
