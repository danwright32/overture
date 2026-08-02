import Foundation

// #1932: what one search runs against, built when the search starts and held until the box empties.
//
// #1926 made the scope something to BUILD rather than something built, so an empty search bar costs
// nothing at all. What remained is that every character rebuilt it: a StageNavigation sweep plus a map
// over every prospect into card values, roughly a twentieth of what it replaced but paid per letter and
// growing with the store.
//
// A search lasts seconds, so the copy is held for a search rather than for the life of the window: the
// next search sweeps again and sees whatever has arrived since. Within one search the results can be a
// few seconds behind a scout or a dismiss, which is the deliberate trade, and the pick routes by key so
// a row that has since gone lands the same way any other missing key does.
//
// A value with its own tests rather than a couple of lines inside a SwiftUI body, because a body cannot
// be evaluated in a unit test and a rule nothing checks is a rule that quietly stops holding.
struct SearchScope {
    private var held: [QueueItem]?

    var isHolding: Bool { held != nil }

    // A search has begun. Sweeps once; asked again while the same search is under way it does nothing,
    // because the field announces the state it is in on every keystroke rather than the transition.
    mutating func begin(_ build: () -> [QueueItem]) {
        guard held == nil else { return }
        held = build()
    }

    // The box is empty again. The copy goes with the search that owned it.
    mutating func end() {
        held = nil
    }

    // What to search. Falls back to the store when nothing is held, which is what makes this an
    // optimisation rather than a second source of truth: on the first character the body can run before
    // the start is announced, and answering with an empty list there would show "no results" for a show
    // that is right in front of Dan.
    func items(_ build: () -> [QueueItem]) -> [QueueItem] {
        held ?? build()
    }
}
