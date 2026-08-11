import Foundation
import SwiftData

// #1802: the backfill that ships WITH the fold change, because a rule only ever reaches rows written
// after it.
//
// Making one venue identity answer for every spelling of a room (dropping a leading article, and folding
// an unlisted room the same way a listed one is folded) changes the key an answer SHOULD be filed under.
// A `VenuePlaceAnswer` already sitting under the old spelling would be looked up by a key nothing computes
// any more: Dan's own sentence about where a room is, invisible, and the room back on his unplaced list
// asking him the same question again.
//
// BLAST RADIUS. It rewrites `venueKey`, a UNIQUE column, and it can delete a row, so it is deliberately
// narrow, and the launch backup taken just before migrations run (#601/#602) is the net under it. The arms
// mirror `OrgKeyRealignmentMigration`, which is the same problem for organisations:
//
//   - A row whose recomputed key equals the one it carries is untouched, which is also what makes a second
//     pass a no-op (idempotent by construction, no flag).
//   - A row whose name no longer yields a key at all keeps the key it has. A fold that failed must not
//     cost Dan an answer he typed.
//   - A row whose key changes and collides with nothing is re-keyed in place.
//   - When two rows land on ONE key they are merged only when they AGREE about the location. The newer
//     answer survives and takes the key; the older, provably redundant one goes.
//   - When they DISAGREE, nothing happens to either: they keep their own keys and the conflict is counted.
//     Two different answers about one room are a question, not a duplicate, and a launch pass may not
//     answer it by picking a side (L5).
enum VenueKeyRealignmentMigration {
    // #2451: the column this pass owns. See `KeyRealignment` for why the list is assembled from the
    // passes rather than written out in one place.
    static let realigns: [KeyRealignment.Field] = [
        KeyRealignment.Field(model: "VenuePlaceAnswer", property: "venueKey",
                             pass: "VenueKeyRealignmentMigration", tableClass: .answer)
    ]

    struct Summary: Equatable {
        var rekeyed = 0            // rows moved onto the key the shared fold now computes
        var duplicatesDeleted = 0  // redundant rows removed by a merge both sides agreed on
        var conflictsDeferred = 0  // groups left untouched because two rows disagreed
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let rows = (try? context.fetch(FetchDescriptor<VenuePlaceAnswer>())) ?? []
        guard !rows.isEmpty else { return Summary() }
        var summary = Summary()

        // Where each row BELONGS under today's fold. A row whose name yields no key is filed under the key
        // it already carries, so it never moves of its own accord.
        var groups: [String: [VenuePlaceAnswer]] = [:]
        for row in rows {
            groups[VenuePlaces.canonicalKey(for: row.venueName) ?? row.venueKey, default: []].append(row)
        }

        var moves: [(row: VenuePlaceAnswer, target: String)] = []
        for (target, group) in groups {
            guard group.count > 1 else {
                if let only = group.first, only.venueKey != target { moves.append((only, target)) }
                continue
            }
            // Newest first: if a merge is allowed, the answer Dan gave most recently is the one that keeps
            // the key.
            let ordered = group.sorted { $0.answeredAt > $1.answeredAt }
            let agree = ordered.allSatisfy { same($0.location, ordered[0].location) }
            guard agree else {
                summary.conflictsDeferred += 1
                continue
            }
            if ordered[0].venueKey != target { moves.append((ordered[0], target)) }
            for redundant in ordered.dropFirst() {
                context.delete(redundant)
                summary.duplicatesDeleted += 1
            }
        }

        // Applied AFTER the loop above, so a row is never re-keyed onto a key another row still holds.
        for move in moves {
            move.row.venueKey = move.target
            summary.rekeyed += 1
        }
        return summary
    }

    // Two answers about one room say the same thing when their text says the same thing. Compared the way
    // Dan typed them rather than by an exact string, because "Tarrytown, NY" and "tarrytown, ny " are one
    // answer and treating them as a conflict would leave both rows stranded under two keys forever.
    private static func same(_ a: String, _ b: String) -> Bool {
        VenuePlaces.normalize(a) == VenuePlaces.normalize(b)
    }
}
