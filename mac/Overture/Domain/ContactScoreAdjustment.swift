import Foundation

// #1648 Phases D and E: makes a show's STORED score agree with its current contact answer, and records
// what the score was before it last moved.
//
// One implementation, called from two places that must never disagree: the probe settle (a fresh answer
// arrived) and the periodic reconcile (an old answer aged out). Both ask the same question, "does this
// row's stored score match the answer it currently has", so a row settles the same way whichever gets
// there first, and neither has to know about the other.
//
// It is a RE-SCORE from the row, never arithmetic on the stored number. That is what makes it safe to
// call repeatedly and from more than one caller: there is no adjustment to apply twice, only a score
// that either already matches the row's answer or does not.
enum ContactScoreAdjustment {
    // Returns whether it changed anything, so a caller can decide whether a save is warranted.
    @discardableResult
    static func settle(_ p: Prospect, now: Date) -> Bool {
        let route = p.contactRouteForScoring(now: now)

        // Already settled at this answer. Covers the common no-op cases in one line: a show nobody has
        // ever checked (unchecked, and nothing recorded), and a row this already ran over.
        let alreadyAt = p.contactRouteAtScore ?? ContactRoute.unchecked.rawValue
        guard route.rawValue != alreadyAt else { return false }

        // The score as it stands BEFORE this adjustment. Read first, because the write below replaces it.
        p.fitScoreBeforeContactCheck = p.fitScore
        let refit = ClassificationOverride.rescored(p, now: now)
        p.fitScore = refit.score
        p.tier = refit.tier.rawValue
        p.contactRouteAtScore = route.rawValue
        return true
    }

    // The periodic half: re-settle every row whose answer has aged past its expiry since the last pass,
    // so a demotion lifts while the app is open rather than only after a relaunch. Cheap, because settle
    // returns immediately for any row already agreeing with its answer, which is nearly all of them.
    //
    // Returns how many rows actually changed, so the caller can skip a save when nothing did and so a
    // count is available rather than a silent sweep (LESSONS L13).
    static func settleAll(_ prospects: [Prospect], now: Date) -> Int {
        prospects.reduce(0) { $0 + (settle($1, now: now) ? 1 : 0) }
    }
}
