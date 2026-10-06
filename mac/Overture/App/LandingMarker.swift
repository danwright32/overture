import Foundation
import Observation

// #4338 (A10): what the landing line (`LandingLine`) shows, held apart from `RootView` for #3885's reason: an
// observable object invalidates only the views that read it, so a landing starting, ending or saying something
// redraws one line of the masthead and nothing else. `RootView` writes it and never reads it in its body.
//
// Three things, each its own field because each changes for its own reason:
//   live         the landing in progress, from the moment its read phase starts to its return
//   surveyed     the interrupted landings and the unreadable landing records, from the latest survey of the
//                landing journals (launch, every idle minute, and after each action)
//   latest       what the latest background landing said: the sweep of kept results, a recovery step, or what
//                one of Dan's actions did
// The entry flush's standing state is read straight from `EntryFlushRecord`, which is observable itself, so a
// refusal reaches the line the moment it happens.
@Observable
@MainActor
final class LandingMarker {
    static let shared = LandingMarker()

    struct Live: Equatable, Sendable {
        var work: LandingWork
        var startedAt: Date
    }

    private(set) var live: Live?
    #if DEBUG
    // The Debug preview's stand in for the landing queue (`LandingPreview`), so the waiting state can be looked at
    // without a second landing holding the store.
    var previewWaitingBehind: LandingSingleFlight.EntryPoint?
    #endif
    private(set) var surveyed = LandingRecovery.Survey()
    private(set) var latest: [LandingOutcome] = []

    init() {}

    func began(_ work: LandingWork, at time: Date) {
        live = Live(work: work, startedAt: time)
    }

    func ended() {
        if live != nil { live = nil }
    }

    // Set only when it differs, so a survey that finds what the last one found redraws nothing.
    func surveyed(_ survey: LandingRecovery.Survey) {
        if survey != surveyed { surveyed = survey }
    }

    // What one background event said. An event that said nothing leaves the last thing said in place, as the
    // status line it replaces did, so a sweep with nothing to report does not erase a warning before it is read.
    func said(_ outcomes: [LandingOutcome]) {
        guard !outcomes.isEmpty, outcomes != latest else { return }
        latest = outcomes
    }

    // The lines to draw now, in the order they are read (L609): standing states first, then the landing in
    // progress (drawn by the line itself, which can tick), then what the latest event said. A latest line that
    // states the same thing a standing line does is left out, so no fact is said twice (L605).
    func standing(editsStuck: (rows: [String], lastTryFailedAt: Date?)?) -> [LandingOutcome] {
        LandingOutcome.standing(interrupted: surveyed.interrupted, unreadable: surveyed.unreadable,
                                editsStuck: editsStuck)
    }

    func latestNotStanding(_ standing: [LandingOutcome]) -> [LandingOutcome] {
        latest.filter { said in !standing.contains(said) }
    }
}
