import Foundation

// #2925: what a census of real contact runs concludes about `no_route_found`.
//
// #2893 shipped the value a run uses to say it found a person and no way to reach them, plus a refusal
// reporting a show whose contacts name a route and supply none. The refusal exists to catch a run
// MISBEHAVING, so it has to be rare. If runs keep doing what the runbook asked for until 2026-08-17,
// naming `form_or_dm` on somebody with no route, the refusal fires on ordinary shows, the card tells Dan
// a check fell short when it did what it always did, and the line gets ignored and then removed (L93).
//
// Separated from the file reading so the verdict can be driven with runs that do not exist on this Mac.
// Every real results file here predates the value, so the branch that matters cannot be reached from the
// live corpus at all, and a decision only ever exercised on the data you happen to have is not exercised
// (L140).
enum NoRouteFoundAdoption {
    struct Run: Equatable, Sendable {
        var label: String
        var contacts: Int
        var noRouteFound: Int
        var showsRefused: Int
        var writtenAt: Date
    }

    enum Verdict: Equatable, Sendable {
        /// No run since the value shipped has carried a contact, so nothing here is about it.
        case nothingToJudgeYet
        /// Runs since it shipped use it, and the refusal is rare. This is what "trust the feature" looks
        /// like.
        case adopted
        /// Runs since it shipped never use it and never trip the refusal either. NOT the all-clear and
        /// NOT the alarm: a run that ignored the instruction and one with no name-only contact to report
        /// are indistinguishable from the outside (L128), so this says exactly that and nothing more.
        case noOccasionToUseIt
        /// The failure #2925 predicted: the refusal is firing on a large share of what runs produce, which
        /// means it is describing the ordinary case rather than a broken run.
        case firingOnTheOrdinaryCase
    }

    /// A run written BEFORE the value existed cannot have used it, so it is not evidence about adoption.
    /// The comparison is inclusive at the moment it shipped: a file written in that same second is on the
    /// new side, which is the direction that cannot manufacture a false accusation out of old data.
    static func verdict(runs: [Run], shippedAt: Date) -> Verdict {
        let since = runs.filter { $0.writtenAt >= shippedAt }
        let contacts = since.reduce(0) { $0 + $1.contacts }
        guard contacts > 0 else { return .nothingToJudgeYet }

        let refused = since.reduce(0) { $0 + $1.showsRefused }
        // Half is deliberately loose. The population is small, this is a trend rather than a gate, and a
        // bar tight enough to fire on one bad run would fire on an ordinary one first.
        if refused * 2 > contacts { return .firingOnTheOrdinaryCase }

        let used = since.reduce(0) { $0 + $1.noRouteFound }
        return used > 0 ? .adopted : .noOccasionToUseIt
    }
}
