import Foundation

// #1587, folded into milestone 32 Phase 2 (#1595): the ONE definition of "Dan has not yet decided about
// this show", so the Scout list he triages and the reachability check he runs over it cannot answer that
// question differently.
//
// They did. `reachabilityProbeCandidateKeys` admitted `.new` and `.queued` and never asked whether the
// run had already opened; `StageNavigation.matches(.scout, ...)` admitted `.new` only and did ask. The
// gap meant the check could offer to spend real money researching a show the queue refuses to display,
// and it is half of why #1585 went unnoticed: two rules, no single place to read the truth. #1570 is the
// precedent for what a second home for one gate costs, and #863 for the fix.
enum OpenForDecision {

    // `performanceDate` is the run's OPENING night. #1540 judges both edges of the window by it: a run
    // that has already started is work Dan will not pitch, so it leaves triage. An undated show cannot be
    // judged and stays open rather than vanishing.
    static func isOpen(status: ReviewStatus, performanceDate: String?,
                       isBooked: Bool, sentAt: Date?, today: String) -> Bool {
        guard !isBooked, sentAt == nil else { return false }
        guard status == .new else { return false }
        return !EasternDate.runHasOpened(openingNight: performanceDate, today: today)
    }
}
