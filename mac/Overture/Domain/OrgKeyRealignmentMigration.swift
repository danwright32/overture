import Foundation
import SwiftData

// #1784: the backfill that ships WITH the rule change, because a rule only ever reaches rows written
// after it. Widening OrgKey to drop a parenthetical (so the ledger and ProducerGate finally agree what
// one organisation is) changes the key an answer SHOULD be filed under. A row already sitting in the
// ledger under the old spelling would be looked up by a key nothing computes any more: invisible, and
// its organisation paid for a second time on the next check.
//
// LIVE-STORE-CLAIM verified=2026-08-07 measure="rows in ZORGREACHABILITYANSWER on Dan's live store"
// Measured before writing this: the ledger holds ZERO rows today, the 2026-08-04 reachability reset
// having cleared it. So on Dan's Mac this pass has nothing to do THIS week, and #1784's own "two of the
// twelve answers are this one series" no longer describes anything in the store. It ships anyway,
// because a check run between now and the install writes rows under the old key, and a backfill that
// exists only if somebody remembers to write it later is the same as no backfill at all.
//
// BLAST RADIUS. It rewrites `orgKey`, a UNIQUE column, and it can delete a row, so it is deliberately
// narrow (the launch backup taken just before migrations run, #601/#602, is the net under it):
//
//   - A row whose recomputed key equals the one it carries is untouched, which is also what makes a
//     second pass a no-op.
//   - A row whose presenter no longer yields a key at all keeps the key it has. A fold that failed must
//     not cost an answer.
//   - A row whose key changes and collides with nothing is re-keyed in place.
//   - When two rows land on ONE key, they are merged only when they AGREE (same verdict, same set of
//     addresses). The newer answer survives and takes the key; the older, provably redundant one goes.
//   - When they DISAGREE, nothing happens to either of them: they keep their own keys and the conflict
//     is counted. Two different answers about one organisation are a question, not a duplicate, and a
//     launch pass may not answer it by picking a side (L5).
enum OrgKeyRealignmentMigration {
    struct Summary: Equatable {
        var rekeyed = 0            // rows moved onto the key the shared fold now computes
        var duplicatesDeleted = 0  // redundant rows removed by a merge both sides agreed on
        var conflictsDeferred = 0  // groups left untouched because two rows disagreed
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let rows = (try? context.fetch(FetchDescriptor<OrgReachabilityAnswer>())) ?? []
        guard !rows.isEmpty else { return Summary() }
        var summary = Summary()

        // Where each row BELONGS under today's fold. A row whose presenter yields no key is filed under
        // the key it already carries, so it never moves of its own accord.
        var groups: [String: [OrgReachabilityAnswer]] = [:]
        for row in rows {
            groups[OrgKey.stored(for: row.presenterName) ?? row.orgKey, default: []].append(row)
        }

        var moves: [(row: OrgReachabilityAnswer, target: String)] = []

        for (target, members) in groups {
            guard members.count > 1 else {
                if members[0].orgKey != target { moves.append((members[0], target)) }
                continue
            }

            // Newest answer wins, with a deterministic tie-break so two rows probed in the same instant
            // do not resolve differently from one launch to the next.
            let ordered = members.sorted {
                $0.probedAt == $1.probedAt ? $0.orgKey < $1.orgKey : $0.probedAt > $1.probedAt
            }
            let winner = ordered[0]
            let losers = ordered.dropFirst()

            guard losers.allSatisfy({ agrees($0, winner) }) else {
                summary.conflictsDeferred += 1
                continue
            }
            for loser in losers {
                context.delete(loser)
                summary.duplicatesDeleted += 1
            }
            if winner.orgKey != target { moves.append((winner, target)) }
        }

        // Two passes, because `orgKey` is UNIQUE and the renames can CHAIN: one row wanting the key a
        // second row is itself about to vacate would collide for as long as both held it, and the group
        // loop's order is a dictionary's, so which one moved first would vary run to run. Every mover is
        // parked on a key nothing else can hold first, and only then given the one it belongs under.
        for (index, move) in moves.enumerated() {
            move.row.orgKey = "\(parkingNamespace)\(index)"
        }
        for move in moves {
            move.row.orgKey = move.target
            summary.rekeyed += 1
        }
        return summary
    }

    // Deliberately outside OrgKey's own namespace, and carrying a character no folded name can produce,
    // so a row caught here by a crash mid-pass is unmistakably a parked row rather than an organisation
    // anybody could look up. The next launch re-derives its key from `presenterName` regardless, since
    // that is what the grouping above reads.
    private static let parkingNamespace = "\u{1}realigning:"

    // Two rows are the same answer when they say the same thing about the organisation: the same verdict,
    // and the same set of addresses. Compared as SETS, since the order two checks happened to write their
    // finds in says nothing about whether they agree.
    private static func agrees(_ a: OrgReachabilityAnswer, _ b: OrgReachabilityAnswer) -> Bool {
        a.resultRaw == b.resultRaw && Set(a.foundEmails) == Set(b.foundEmails)
    }
}
