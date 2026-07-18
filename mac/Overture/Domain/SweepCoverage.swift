import Foundation

// #897: verifying a stitched multi-month page was actually READ IN FULL before its feed is trusted for
// reconcile.
//
// #858 stitches several months of a calendar into ONE pinned page under per-month markers, and the app
// hashes all of them together. But a run that reads three of four marked sections does not fail: it
// simply returns fewer shows, and on the watchlist that shortfall reads as "those shows were cancelled".
// Nothing in the run's own verdict can tell "this calendar lists 16" from "the run read 16 of the 30 it
// was handed", because a show the run never returned is not a show it rejected (#887's guard never sees
// it), and 16 of 30 still clears every size gate (#910/#917 keep it from re-baselining or cancelling on
// its own, but neither can tell the two apart; that is what this closes).
//
// The one fact the app holds that the run cannot fake is the SET of months it stitched into the page
// (SourceFetcher records it as it builds the pin, and persists it on the source). The run reports the
// months it actually read back (`monthsCovered`). A sweep is complete only when the run covered every
// month the app put in front of it; a shortfall is a NAMED incomplete read, not a smaller trusted feed.
enum SweepCoverage {
    // Was every stitched month actually read?
    //
    // A single-month page (the watchlist default, monthHorizon 1) is trivially complete: there is nothing
    // to under-read, and `monthsCovered` is not even asked for. This is the property that keeps the whole
    // check DORMANT until pagination is turned on above one month, so it cannot change any live behavior
    // today, exactly where #858 left the safety line.
    //
    // Above one stitched month, completeness requires the run to have reported its coverage AND that
    // coverage to include every stitched month. A run that reported nothing (an older workflow that does
    // not yet echo `monthsCovered`) is treated as INCOMPLETE, not complete: the safe direction is to
    // distrust a sweep we cannot confirm was whole, never to assume it. Extra months in the report beyond
    // what was stitched are harmless; only a MISSING stitched month makes the sweep short.
    static func isComplete(stitchedMonths: [String], monthsCovered: [String]?) -> Bool {
        guard stitchedMonths.count > 1 else { return true }
        guard let covered = monthsCovered else { return false }
        return Set(stitchedMonths).isSubset(of: Set(covered))
    }
}
