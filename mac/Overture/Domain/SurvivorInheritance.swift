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
    static func carry(onto survivor: Prospect, from members: [Prospect]) -> String? {
        // The show was first seen when the EARLIEST of these rows first saw it. Moved here from
        // NaturalKeyVenueMigration, which was the only pass doing it.
        let firstSightings = members.compactMap(\.firstSeenAt)
        if let earliest = firstSightings.min(),
           survivor.firstSeenAt == nil || earliest < survivor.firstSeenAt! {
            survivor.firstSeenAt = earliest
        }
        NaturalKeyVenueMigration.carryDansDecisions(onto: survivor, from: members)
        return NaturalKeyVenueMigration.carryTheFeedIdentity(onto: survivor, from: members)
    }
}
