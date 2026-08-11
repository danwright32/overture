import Foundation
import SwiftData

// #2451: the realignment that ships WITH the OrgKey fold change, for the one table where a merge would
// be a data loss rather than a tidy-up.
//
// `OrgKey.of` now drops a leading article, so an organisation-scoped refusal filed under
// `presenter:the green room 42` is looked up under `presenter:green room 42` from the next launch on. A
// refusal nobody can look up is a refusal that has stopped refusing, and nothing on any screen says so:
// the address simply reappears on the card, and the next prep run pays to rediscover it. That is #2392
// leading to #2421, and it is the loss this milestone exists to prevent.
//
// WHY THIS IS NOT `OrgKeyRealignmentMigration` WITH A DIFFERENT FETCH. That pass carries a
// `duplicatesDeleted` counter and deletes at the point two rows agree, and those semantics were chosen
// for reachability ANSWERS, where a redundant duplicate really is disposable. Copied onto a refusal
// ledger they mean a fold change can delete a refusal, silently, reported as a merge both sides agreed
// on. Two refusals can only ever mean refuse, so there is no disagreement for a merge to resolve here
// and no reason to remove a row (L42).
//
// BLAST RADIUS, stated the way the two shipped passes state theirs:
//
//   - It NEVER deletes. There is no `context.delete` in this file and no `duplicatesDeleted` counter to
//     put a number in, and `RefusalRealignmentNeverDeletesTests` fails if either appears.
//   - It touches ONLY organisation-scoped rows whose key is in `OrgKey`'s own namespace. Those are two
//     independent conditions on purpose (L70): `scopeId` also holds a prospect's natural key on a
//     show-scoped row, and re-folding one of those would move a refusal onto a key naming nothing.
//   - A row whose recomputed key equals the one it carries is untouched, which is also what makes a
//     second pass a no-op.
//   - A row whose stored key no longer folds at all keeps the key it has and is counted. A fold that
//     failed must not cost a refusal.
//   - When a re-key would collide with a refusal that already exists (the same address struck for both
//     spellings of one organisation), BOTH rows are kept, each under its own key, and the collision is
//     counted. The row that could not move goes on refusing under the spelling it was written with,
//     which costs nothing, because a refusal only ever adds a refusal.
enum RefusedOrgKeyRealignment {

    static let realigns: [KeyRealignment.Field] = [
        KeyRealignment.Field(model: "RefusedContactAddress", property: "scopeId",
                             pass: "RefusedOrgKeyRealignment", tableClass: .protective)
    ]

    // Deliberately with no `duplicatesDeleted`. There is no number this pass could put in one, and a
    // counter that can only ever read zero is a claim that deleting is a thing this path does.
    struct Summary: Equatable {
        var rekeyed = 0             // refusals moved onto the key the shared fold now computes
        var collisionsKeptBoth = 0  // a move refused because the target key is already refused; both kept
        var unkeyable = 0           // rows whose stored key no longer folds; left exactly as they are
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let rows = (try? context.fetch(FetchDescriptor<RefusedContactAddress>())) ?? []
        guard !rows.isEmpty else { return Summary() }
        var summary = Summary()

        struct Move { let row: RefusedContactAddress; let scopeId: String; let id: String }

        // Every id that will still be held once this pass finishes. It starts as every id held NOW, and
        // a row releases its old one only at the moment it successfully claims a new one, so two rows can
        // never both be promised the same id whatever order the fetch happened to return them in.
        var occupied = Set(rows.map(\.id))
        var moves: [Move] = []

        // Sorted, so which of two rows contending for one key gets to move is the same on every machine
        // and on every launch, rather than a dictionary's or a fetch's order.
        for row in rows.sorted(by: { $0.id < $1.id })
        where row.scopeRaw == ContactRefusal.Scope.organisationRaw {
            guard let target = OrgKey.realigned(storedKey: row.scopeId) else {
                summary.unkeyable += 1
                continue
            }
            guard target != row.scopeId else { continue }
            let targetId = ContactRefusal.rowId(scopeRaw: row.scopeRaw, scopeId: target,
                                                handleKey: row.handleKey)
            guard !occupied.contains(targetId) else {
                summary.collisionsKeptBoth += 1
                continue
            }
            occupied.remove(row.id)
            occupied.insert(targetId)
            moves.append(Move(row: row, scopeId: target, id: targetId))
        }

        // Two passes, because `id` is UNIQUE and a claimed id can be one another mover is itself about to
        // vacate: for as long as both held it the store would refuse the write. Every mover is parked on
        // an id nothing else can hold first, and only then given the one it belongs under. The parking
        // namespace carries a character no folded name can produce, so a row caught here by a crash
        // mid-pass is unmistakably a parked row; the next launch re-derives its key from `scopeId`
        // regardless, which is what the loop above reads.
        for (index, move) in moves.enumerated() {
            move.row.id = "\(parkingNamespace)\(index)"
        }
        for move in moves {
            move.row.scopeId = move.scopeId
            move.row.id = move.id
            summary.rekeyed += 1
        }
        return summary
    }

    private static let parkingNamespace = "\u{1}realigning-refusal:"
}
