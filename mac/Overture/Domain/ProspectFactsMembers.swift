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

// #4357 slice B, T4: a stored show as the producer gate reads it, its presenter and its venue and nothing
// else. Every place that builds the producer tables or the brand list from stored shows projects through
// this one initialiser (the queue's pass and its memo key, the scout's brand corpus, the prep run's house
// list, the possible match recheck), so a field the gate starts reading is added once and reaches all of
// them, and the engine hands it a retained `RowFacts` by the same call.
extension ProducerGate.Show {
    init(_ row: some ProspectFacts) {
        self.init(presenter: row.presenter, venue: row.venue)
    }
}

// #4357 slice B, T5: a stored show as the organisation answer ledger reads it. `hasOwnAnswer` is whether the
// show's own contact check has run, which is what keeps a paid verdict from being overwritten by a fan-out.
extension OrgAnswerLedger.Show {
    init(_ row: some ProspectFacts) {
        self.init(key: row.naturalKey, presenter: row.presenter, venue: row.venue,
                  hasOwnAnswer: row.reachabilityProbedAt != nil)
    }
}
