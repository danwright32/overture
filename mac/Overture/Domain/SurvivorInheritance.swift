import Foundation
import SwiftData

// #3597 / #3379: what a surviving Prospect inherits before its duplicates are deleted, in ONE place.
//
// THREE passes delete a Prospect at every launch, and before this each carried a different subset, so
// what a merge cost Dan depended on which pass happened to run. Measured on main at e7c1f529:
//
//   pass                        | feed identity | Dan's decisions | firstSeenAt
//   SameNightTitleVariantMerge  | yes           | no              | no
//   DriftedRunMerge             | no            | no              | no
//   NaturalKeyVenueMigration    | no            | yes             | yes
//
// Nine cells, three filled, and `DriftedRunMerge` carried nothing at all. #3379 asked for exactly this
// and was closed when the helper it named was created, with one of the three passes wired to it (L30,
// L38, L613: a shared component created to end N copies converts the one site in front of whoever built
// it and leaves the rest standing).
//
// Each carry is a different loss, which is why none is optional:
//   firstSeenAt      the funnel's opening node (#16) jumps forward to whenever the duplicate appeared
//   Dan's decisions  a rename or a kept-visible flag he set is gone, and the survivor then asserts the
//                    opposite of what happened (L163)
//   feed identity    the survivor keeps a key the feed stopped matching, so a live show goes on reading
//                    as "may be cancelled" (#3278's class, #3582)
//   found addresses  the only one that costs MONEY to replace: a contact found by a paid check is deleted
//                    with the row that holds it and comes back only by paying again (#4060, #1845)
enum SurvivorInheritance {

    // Returns the natural key the survivor should ADOPT, or nil when there is nothing to adopt. The key is
    // returned rather than assigned for the reason `carryTheFeedIdentity` already records: the losers must
    // be gone before the survivor can take a key one of them holds, or the write lands on the unique index
    // while they are still there (#2754 measured that SwiftData does not throw on that collision, it
    // silently MERGES the rows, so the ordering is not a nicety). Every caller therefore calls this BEFORE
    // its delete loop and assigns the returned key AFTER it.
    //
    // A caller may legitimately discard the returned key, and `NaturalKeyVenueMigration` does: it re-keys
    // to a COMPUTED key rather than to the feed's, which #3597 flagged as possibly a third correct answer
    // rather than a gap. That question is left open deliberately and is named in this change's PR body;
    // what is NOT left open is the other two carries, which that pass was missing outright.
    @discardableResult
    static func carry(onto survivor: Prospect, from members: [Prospect],
                      now: Date = Date()) -> String? {
        // The show was first seen when the EARLIEST of these rows first saw it. Moved here from
        // NaturalKeyVenueMigration, which was the only pass doing it.
        let firstSightings = members.compactMap(\.firstSeenAt)
        if let earliest = firstSightings.min(),
           survivor.firstSeenAt == nil || earliest < survivor.firstSeenAt! {
            survivor.firstSeenAt = earliest
        }
        NaturalKeyVenueMigration.carryDansDecisions(onto: survivor, from: members)
        carryTheFoundAddresses(onto: survivor, from: members)
        markAwaitingTheFeed(survivor, members: members, now: now)
        return NaturalKeyVenueMigration.carryTheFeedIdentity(onto: survivor, from: members)
    }

    // #4060: the losers' contacts MOVE to the survivor before the caller deletes them.
    //
    // `recipients` is a cascade relationship, so deleting a Prospect destroys every Recipient hanging off
    // it. Nothing anywhere carried them, and the ladder that looks as though it protects against this does
    // not: `richestContactList` picks the LONGER list, which means the shorter one is deleted rather than
    // kept, and it is only consulted at all once the rung above it has found nobody.
    //
    // Measured on Dan's live store at the 2026-09-20 14:00 launch, which is a merge that had already
    // happened by the time this was written. `Operation Mincemeat: Mission Recast` pk 491 collapsed onto
    // pk 1371 and its four recipients went with it, one of them carrying a real email; the store's
    // recipient count fell 385 to 381 between that launch's backup and the one before it, and the survivor
    // holds no contacts at all today.
    //
    // Deduped on the recipient's own `id`, which IS the canonicalised address or the `form:` handle
    // (`Recipient.makeId`), never on the name: two rows holding one address are one contact, and two
    // people who share a name are not (the rule `DuplicateContactMerge` already refuses to cross, L370).
    // An id that is EMPTY is carried rather than deduped, because an empty key is not evidence of a match
    // and folding two of them together would delete an address on the strength of both being unreadable
    // (0 of the store's 381 recipients carry one today, so this is the unreachable branch and is written
    // to fail towards keeping a row).
    //
    // Nothing is deleted here and no field of a carried row is rewritten. A recipient the survivor already
    // holds stays exactly as it is, and the loser's copy of it is destroyed with its row, which is the
    // same address either way.
    private static func carryTheFoundAddresses(onto survivor: Prospect, from members: [Prospect]) {
        var held = Set(survivor.recipients.map(\.id).filter { !$0.isEmpty })
        var moving: [(loser: Prospect, recipient: Recipient)] = []
        for loser in members where loser.persistentModelID != survivor.persistentModelID {
            for recipient in loser.recipients {
                if !recipient.id.isEmpty {
                    guard !held.contains(recipient.id) else { continue }
                    held.insert(recipient.id)
                }
                moving.append((loser, recipient))
            }
        }
        // Collected first, then applied: both sides of the relationship are mutated, and rewriting a
        // loser's `recipients` while iterating it is how a carry silently skips every other row.
        for move in moving {
            move.loser.recipients.removeAll { $0.persistentModelID == move.recipient.persistentModelID }
            survivor.addRecipient(move.recipient)
        }
    }

    // #3596: the question this merge leaves behind, stamped on the survivor so the next sweep can answer
    // it. HERE rather than in each pass, because all three deleting passes already call `carry`, and a
    // shared component that converts the one site in front of whoever built it and leaves the rest is the
    // exact failure this file's own header records (L613, L621).
    //
    // ONLY where something was actually merged. `members` includes the survivor, so a single member is a
    // cluster that merged nothing, and marking those would put the question on rows no pass touched and
    // make the next sweep report the whole store (L104).
    //
    // It OVERWRITES an outstanding mark rather than keeping the older one. Two merges before a sweep is
    // one question, not two, and it is about the identity the survivor holds now.
    //
    // It does NOT clear `mergeSurvivorUnseenAt`. A finding from a previous cycle is a fact about what
    // happened then, and a fresh merge is not evidence that it was wrong; the sweep clears it, by
    // listing the row.
    private static func markAwaitingTheFeed(_ survivor: Prospect, members: [Prospect], now: Date) {
        guard members.count > 1 else { return }
        survivor.survivedMergeAt = now
    }
}
