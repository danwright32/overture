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

    // #4357 slice D1: the typed views and rules the reached-out terms read about the SHOW, with one body for
    // both conformers. As on `ContactFacts` (ContactFactsMembers.swift), `status`, `showOutcome` and
    // `outcome` keep get/set properties on `Prospect` for the writers, and their getters read these bodies
    // through `Prospect.asProspectFacts`.
    var status: ReviewStatus { ReviewStatus(rawValue: statusRaw) ?? .new }

    // #2394: the typed ending, the one field every reader shares.
    var showOutcome: ShowOutcome? { showOutcomeRaw.flatMap(ShowOutcome.init(rawValue:)) }

    var outcome: Outcome { Outcome.fromStored(outcomeRaw) }

    // Over `factContacts`, which on a model is the COUNTED accessor, so a generic term asking this pays for
    // the contacts it reads in `WorkTally.recipientReaches`. `Prospect.performanceStatus` keeps reading its
    // own `recipients` uncounted, as it did, through the same rule (`PerformanceStatus.of(_:contacts:)`), so
    // no count the existing surfaces are pinned at moves.
    var performanceStatus: PerformanceStatus { PerformanceStatus.of(self, contacts: factContacts) }

    // #2225/#2226: the ONE place that answers "has this show booked", folded from both levels by
    // `performanceStatus`. Mirrors `Prospect.isBooked`, which reads the model's own `performanceStatus`.
    var isBooked: Bool { performanceStatus == .booked }

    // #4357 slice E2: the two `ReplyWatchable` members, moved from `Prospect`'s conformance (which they still
    // satisfy) so a retained show answers the conversation proposal and the nudge list by them.
    var replyWatchManualOutcome: Bool { outcomeSourceRaw == OutcomeSource.manual.rawValue }
    var replyWatchIsBooked: Bool { outcome == .booked }

    // #4357 slice E2: `Prospect.hasUnhandledReply` over the contacts handed in, which that property now reads
    // with its own `recipients`. Somebody wrote back and is waiting, unless the show booked.
    func hasUnhandledReply(among contacts: [some ContactFacts]) -> Bool {
        PerformanceStatus.of(self, contacts: contacts) != .booked && contacts.contains(where: \.hasUnhandledReply)
    }

    // In force unless the contact has written back since. Takes the contact's own reply stamp because the
    // reopen is per person: one contact replying does not put the whole show back in play for everyone
    // else, but it does put THAT conversation back in play.
    func isOutreachStoodDown(asOf repliedAt: Date?) -> Bool {
        guard let stoodDown = outreachStoodDownAt else { return false }
        if let repliedAt, repliedAt > stoodDown { return false }
        return true
    }
}

extension Prospect {
    /// #4357 slice D1: this show seen only as `ProspectFacts`, so a member read through it reaches the
    /// protocol's one body above rather than the same-named property this model keeps for its setter.
    /// Without it, a getter on `Prospect` that named its own property would call itself.
    var asProspectFacts: some ProspectFacts { self }
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
