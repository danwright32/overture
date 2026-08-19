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
        namedOrganiser(presenter: presenter) == nil
    }

    // #2983: the organiser's NAME, on exactly the terms the flag above answers about it.
    //
    // Derived one from the other rather than written twice, because the defect this fixes was precisely a
    // flag about a fact standing in for the fact: a queue saying "an organisation IS named here" while
    // carrying no name is the same failure again, one layer down, and two spellings of the same trim is
    // how that comes about. So there is one predicate, and `onlyTheActIsNamed` is now defined as "this
    // returned nothing".
    //
    // Trimmed, and nil rather than empty for a blank, for the reason the flag already gave: the extraction
    // boundary writes an empty string when it drains a room's own name (#1787), so a nil-only test would
    // miss the commonest row in this class. Returning the TRIMMED value also means no reader ever receives
    // a name padded with the whitespace that made it look present.
    static func namedOrganiser(presenter: String?) -> String? {
        let trimmed = (presenter ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
