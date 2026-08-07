import Foundation

// #2203: what the Scouting phase is doing AFTER its counted part has finished.
//
// The sweep reports once per fetched source, so "N of M done" pins at the total the instant the fetch
// loop ends. The phase is nowhere near over at that point: the read-budget decision, the hand-off to the
// reader and its detached launch, the deferred report, the booking reconcile over the whole store, the
// blocked-town retirement, and the saves all still have to happen, and none of them reported anything.
//
// Two things went wrong because of that, and they are the same standing rule from two directions. The
// count made a promise it could not keep, so a phase that had finished one part looked frozen; and
// `advancedAt` stopped moving, so the sweep's only evidence of life expired and a slow tail was judged
// stuck by the wall clock alone. Working, still alive, and failed have to be visibly different states,
// and a count that cannot move is none of them.
//
// A named step rather than a longer count: the tail's parts are not units of one kind of work, so
// counting them would invent a denominator, and what Dan needs to know while he waits is what is
// happening, not how far through an arbitrary list it is.
enum ScoutSweepStep: String, Equatable, Sendable, CaseIterable {
    case handingPagesToTheReader
    case checkingBookings
    case clearingBlockedTowns
    case saving

    // The sentence Dan reads. Here rather than in the view so it reaches `docs/copy-inventory.md` and can
    // be read cold, and so the two surfaces that could show it cannot word it differently.
    var line: String {
        switch self {
        case .handingPagesToTheReader: return "Handing the changed pages over to be read"
        case .checkingBookings: return "Checking what it found against your bookings"
        case .clearingBlockedTowns: return "Clearing out shows in towns you blocked"
        case .saving: return "Saving what this run found"
        }
    }
}
