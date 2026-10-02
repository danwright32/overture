import Foundation

// #4357 (plan v7 Phase 3 step 1): the computed members a ported queue term reads, moved here from `Prospect`
// so both conformers of `ProspectFacts`, the live model and the retained `RowFacts`, answer them by ONE body.
// A copy on `RowFacts` beside the one on `Prospect` would be two definitions of one fact, and they would
// drift (L263, L370).
//
// In a file of its own rather than in `QueueFacts.swift`, because that file is the field LIST, which
// `TestOnlyReachableDomainCodeTests` deliberately does not count as a use of anything it names. A rule here
// is a real reader, and must be counted as one.
extension ProspectFacts {
    // Gone from the feed: absent across enough consecutive scouts to rule out a transient
    // partial feed (#133). Cancelled or pulled, not merely a one-off glitch.
    var disappearedFromFeed: Bool { missedScoutCount >= FeedReconcile.goneThreshold }
}
