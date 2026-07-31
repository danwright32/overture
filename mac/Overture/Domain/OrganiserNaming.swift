import Foundation

// #1856: one definition of "this show names nobody but the act".
//
// The question was already being asked in two places that could not see each other: the free reachability
// heuristic (an empty presenter means there is nothing to email) and, from now on, the queue the contact
// check reads. A second spelling of the same rule is how two surfaces end up disagreeing about the same
// row, so both go through here.
//
// It is deliberately a fact about the ROW, not about why the row looks that way. `presenterWasTheRoom`
// records that Overture drained a presenter that was only the room's own name (#1787), which is true of 78
// of the 93 organiser-less shows on the live store; the other 15 came from pages that named nobody, or
// from a scout older than that flag. All 93 have the same problem and want the same answer (Dan's scope
// call, 2026-07-31).
enum OrganiserNaming {
    // True when no presenting organisation is named for this show. Whitespace is not a name: the
    // extraction boundary writes an empty string rather than nil when it drains a room's own name, so a
    // nil-only test would miss the commonest row in this class.
    static func onlyTheActIsNamed(presenter: String?) -> Bool {
        (presenter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
