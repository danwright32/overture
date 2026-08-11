import Foundation
import SwiftData

// #2451: the realignment for Dan's own producer/house corrections, which are ANSWER shaped.
//
// `PromotedProducer.orgKey` and `DemotedHouse.orgKey` store `ProducerGate.key`'s output and nothing
// else: no raw name, no display spelling. So unlike the two shipped passes, this one cannot re-derive a
// key from a name the row kept. It re-folds the STORED key instead, which is sound because every fold
// the key is built from is idempotent, and it is the only thing available. Its consequence is worth
// stating: a row can only ever be moved by a fold change that is visible in the key itself, so a change
// that needs the original spelling to undo would need those rows to start carrying one.
//
// This is `OrgKeyRealignmentMigration`'s merge-on-agreement behaviour, not `RefusedOrgKeyRealignment`'s
// re-key-only one, and the reason is the reason #2451 splits the two at all: a correction is a verdict,
// so two rows in ONE table landing on one key say the same thing twice and merging them loses nothing.
//
// BLAST RADIUS. It rewrites `orgKey`, a UNIQUE column in both tables, and it can delete a row (the
// launch backup taken just before migrations run, #601/#602, is the net under it):
//
//   - A row whose recomputed key equals the one it carries is untouched, which is what makes a second
//     pass a no-op.
//   - A row whose key no longer folds at all keeps the key it has.
//   - Two rows in the SAME table landing on one key are one correction written twice. The newest keeps
//     the key; the older, provably redundant one goes.
//   - A promotion and a demotion landing on ONE key is a CONTRADICTION, not a duplicate, and neither
//     side is touched. `ProducerOverrideEditing` enforces mutual exclusion when Dan makes a correction,
//     so the store can only reach this state through a re-key, and a launch pass may not decide which
//     of two things he said is the one he meant (L5). The conflict is counted and both rows keep their
//     own keys, which leaves the gate reading exactly what it read before.
enum ProducerOverrideKeyRealignment {

    static let realigns: [KeyRealignment.Field] = [
        KeyRealignment.Field(model: "PromotedProducer", property: "orgKey",
                             pass: "ProducerOverrideKeyRealignment", tableClass: .answer),
        KeyRealignment.Field(model: "DemotedHouse", property: "orgKey",
                             pass: "ProducerOverrideKeyRealignment", tableClass: .answer),
    ]

    struct Summary: Equatable {
        var rekeyed = 0            // corrections moved onto the key the gate's fold now computes
        var duplicatesDeleted = 0  // one correction written twice, collapsed
        var conflictsDeferred = 0  // a promotion and a demotion on one key, both left alone
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let promoted = (try? context.fetch(FetchDescriptor<PromotedProducer>())) ?? []
        let demoted = (try? context.fetch(FetchDescriptor<DemotedHouse>())) ?? []
        guard !promoted.isEmpty || !demoted.isEmpty else { return Summary() }
        var summary = Summary()

        let promotedGroups = grouped(promoted, key: \.orgKey, addedAt: \.addedAt)
        let demotedGroups = grouped(demoted, key: \.orgKey, addedAt: \.addedAt)

        // A target claimed on both sides is a contradiction, and it is worked out BEFORE either table is
        // touched: resolving one table first would leave the other looking at a store that had already
        // moved under it.
        let contradicted = Set(promotedGroups.keys).intersection(demotedGroups.keys)
        summary.conflictsDeferred = contradicted.count

        let promotedMoves = resolve(promotedGroups, skipping: contradicted, key: \.orgKey,
                                    context: context, summary: &summary)
        let demotedMoves = resolve(demotedGroups, skipping: contradicted, key: \.orgKey,
                                   context: context, summary: &summary)

        // Parked first, then moved, because `orgKey` is UNIQUE and the renames can CHAIN: a row wanting
        // the key a second row is itself about to vacate would collide for as long as both held it.
        apply(promotedMoves, key: \.orgKey, summary: &summary)
        apply(demotedMoves, key: \.orgKey, summary: &summary)
        return summary
    }

    // Where each row BELONGS under today's fold, newest first inside each group. A row whose key no
    // longer folds is filed under the key it already carries, so it never moves of its own accord. The
    // tie-break is the key itself, so two corrections made in the same instant do not resolve one way on
    // one launch and the other way on the next.
    private static func grouped<Row: AnyObject>(_ rows: [Row], key: KeyPath<Row, String>,
                                                addedAt: KeyPath<Row, Date>) -> [String: [Row]] {
        var out: [String: [Row]] = [:]
        for row in rows {
            let stored = row[keyPath: key]
            out[ProducerGate.key(stored) ?? stored, default: []].append(row)
        }
        return out.mapValues { members in
            members.sorted {
                $0[keyPath: addedAt] == $1[keyPath: addedAt]
                    ? $0[keyPath: key] < $1[keyPath: key]
                    : $0[keyPath: addedAt] > $1[keyPath: addedAt]
            }
        }
    }

    // The newest member of each group keeps the key; every other member is the same correction written
    // twice and goes. Returns only the rows that actually have to move.
    private static func resolve<Row: PersistentModel>(
        _ groups: [String: [Row]], skipping contradicted: Set<String>,
        key: ReferenceWritableKeyPath<Row, String>, context: ModelContext,
        summary: inout Summary) -> [(row: Row, target: String)] {
        var moves: [(row: Row, target: String)] = []
        for (target, members) in groups.sorted(by: { $0.key < $1.key })
        where !contradicted.contains(target) {
            guard let survivor = members.first else { continue }
            for redundant in members.dropFirst() {
                context.delete(redundant)
                summary.duplicatesDeleted += 1
            }
            if survivor[keyPath: key] != target { moves.append((survivor, target)) }
        }
        return moves
    }

    private static func apply<Row: PersistentModel>(_ moves: [(row: Row, target: String)],
                                                    key: ReferenceWritableKeyPath<Row, String>,
                                                    summary: inout Summary) {
        for (index, move) in moves.enumerated() {
            move.row[keyPath: key] = "\(parkingNamespace)\(index)"
        }
        for move in moves {
            move.row[keyPath: key] = move.target
            summary.rekeyed += 1
        }
    }

    // Outside any fold's own namespace and carrying a character no folded name can produce, so a row
    // caught here by a crash mid-pass is unmistakably parked rather than an organisation anybody could
    // look up. The next launch re-folds it regardless, since that is what the grouping above reads.
    private static let parkingNamespace = "\u{1}realigning-override:"
}
