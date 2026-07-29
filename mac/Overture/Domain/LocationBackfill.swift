import Foundation
import SwiftData

// #1744: fill `location` on the rows ALREADY in the store, by the same rule new ingests now use.
//
// Without this the fix would be forward-only and would arrive one source at a time over weeks. A stored
// row's location is only rewritten when the hash-gated scout re-emits that row, so Carnegie's 75 blank
// rows would stay blank until Carnegie's calendar happened to change, and the whole defect Dan reported
// (the town refusal withheld, the gate a no-op, the card with no city) would persist on the queue he is
// looking at right now. #1600 and #1693 both had to add a launch pass for exactly this reason.
//
// LIVE-STORE-CLAIM verified=2026-07-29 measure="untriaged prospects with a blank `location`, run through the real fill and the real geography gate"
// Measured against the live store before shipping: of 342 blank untriaged rows, 341 get a place (311 from
// the shared venue table, 23 from an address baked into the venue string, 7 from the tour-title
// convention) and 1 stays blank. 21 of the newly-placed rows then place OUT of Dan's range and leave the
// queue, which is the gate finally running rather than a loss: 7 Carnegie tour dates abroad, 4 Washington
// DC recitals, 3 Atlanta and 1 Fort Worth touring production, 1 Enterprise Alabama and 1 Vancouver ballet
// date, and 4 in-region choral dates outside the five boroughs (3 in Chatham NJ, 1 in Mamaroneck NY) that
// his music rule has always excluded.
//
// IDEMPOTENT, and only ever additive: it fills a blank and never rewrites a location a row already has,
// so a page's own words and anything Dan corrected both survive every future launch. It runs every
// launch rather than once, because a row can arrive blank at any time (a venue this table does not know
// yet) and because a later table entry should reach the rows that were waiting for it.
enum LocationBackfill {
    // Returns how many rows it placed, so a caller can report what it actually did.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        // Fetched unfiltered and narrowed in Swift on purpose: the condition is "nil OR empty after
        // trimming", which #Predicate cannot express over an optional string, and a predicate that
        // matched only `nil` would silently skip every row holding a whitespace-only location.
        guard let rows = try? context.fetch(FetchDescriptor<Prospect>()) else { return 0 }
        var placed = 0
        for p in rows where (p.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The SCOUT's title, not Dan's rename. The tour-title rule reads a convention the SOURCE
            // writes ("NYO2 in Santo Domingo, Dominican Republic"), and a row Dan has retitled by hand no
            // longer carries it, so reading his name would quietly stop placing exactly the rows he has
            // touched. `scoutGroupName` is nil on rows predating that field, where groupName IS the
            // scout's title.
            guard let filled = EventLocationFill.location(title: p.scoutGroupName ?? p.groupName,
                                                          venue: p.venue,
                                                          published: nil) else { continue }
            p.location = filled
            placed += 1
        }
        return placed
    }
}
