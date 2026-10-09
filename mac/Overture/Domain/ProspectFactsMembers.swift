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

    // #4357 slice G1: the reachability verdict and the two route lists it reads, moved from `Prospect` with
    // their comments, over the contacts handed in rather than the model's `recipients`.
    var reachabilityResult: Reachability.ProbeResult? {
        reachabilityResultRaw.flatMap(Reachability.ProbeResult.init(rawValue:))
    }

    // The verdict the BADGE reads: the stored one while a sent or booked show is a record, and re-derived
    // from the contacts handed in otherwise. Comments on `Prospect.reachabilityResultAsHeld` (#2717).
    func reachabilityResultAsHeld(among contacts: [some ContactFacts]) -> Reachability.ProbeResult? {
        guard let stored = reachabilityResult else { return nil }
        guard sentAt == nil, PerformanceStatus.of(self, contacts: contacts) != .booked else { return stored }
        return reachabilityResultFromRecipients(among: contacts)
    }

    func reachabilityResultFromRecipients(among contacts: [some ContactFacts]) -> Reachability.ProbeResult {
        // #3653: the cascade itself lives in `Reachability.result(from:)` so a tier-one row can ask the
        // same question without hand-rolling a second copy of it. What stays here is gathering the facts,
        // which is the only part that needs a model.
        //
        // ONE WALK, not four. Each arm used to ask the contacts separately (`hasUnguardedAddress`,
        // `isHeldByAGuard`, `usableContactFormURLs`, `socialRouteURLs`), and short-circuiting only helped
        // the rows that answered early. The two URL lists are still computed lazily, because a row with
        // an address never needs them and they are the expensive pair.
        //
        // #3387: `hasUnguardedAddress`, not `isSendablePending`. This asks whether an address exists that
        // no research guard is holding; the send predicate folds in a calendar conflict, a blank subject
        // and two lint judgements, none of which is a fact about reachability.
        // #1798: guarded through the ONE shared definition (`Recipient.isHeldByAGuard`), which lists every
        // guard that can hold an address. This rule once listed two of the three, so an address held only
        // as a possible duplicate fell through to "no address at all".
        var unguarded = false
        var guarded = false
        for r in contacts {
            if r.hasUnguardedAddress { unguarded = true; break }
            if r.isHeldByAGuard { guarded = true }
        }
        if unguarded { return Reachability.result(from: .init(hasUnguardedAddress: true)) }
        if guarded { return Reachability.result(from: .init(hasGuardedAddress: true)) }
        return Reachability.result(from: .init(hasUsableContactForm: !usableContactFormURLs(among: contacts).isEmpty,
                                               hasSocialRoute: !socialRouteURLs(among: contacts).isEmpty))
    }

    // #2612: the social profiles Dan will actually DM. Judged through the SAME venue and press guards as
    // the form list below, so a room's own Instagram or a press account is no more a route here than it
    // is there; only the social-host test differs, and it is inverted.
    // #2912: and never a profile the run itself called a NAME MATCH ONLY. This list is what makes the
    // show read as reachable (the stored verdict, the fit score, the organisation ledger, and whether
    // Dan can record a DM he sent by hand), and every one of those is Overture ASSERTING that a way in
    // exists. An account carrying the right name and nothing tying it to this show cannot support that
    // claim, so the assertion side sees exactly what it saw when such a profile was refused outright
    // (#2147, L75). The CARD still shows the handle, marked, because looking at it costs Dan seconds.
    func socialRouteURLs(among contacts: [some ContactFacts]) -> [String] {
        contacts.compactMap { r -> String? in
            guard !r.isUnconfirmedNameMatch,
                  let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, Reachability.isSocialOnly(raw),
                  !VenueContactGuard.looksLikeVenue(formURL: raw, venue: venue),
                  !PressContactGuard.looksLikePressContact(formURL: raw) else { return nil }
            return raw
        }
    }

    // #1626: the contact forms Dan would actually use, which is a form on the ACT's own site. An
    // Instagram or another login-walled page is a dead end (his rule, 2026-07-27), judged through the
    // one shared social-host list rather than a second copy of it.
    //
    // #1629: and never the ROOM's own booking form, judged through the same VenueContactGuard
    // comparison the email path has used since #388. Without it a check that returned the host venue's
    // form gave a card reading "Contact form only" that pointed Dan straight at the room, which is the
    // oldest standing rule in the product (#368: a room's own address is never a real contact, not even
    // a named booking person). Excluding it here means the show falls through to `noEmailFound`, the
    // same answer he would get if the check had returned the room's email address.
    func usableContactFormURLs(among contacts: [some ContactFacts]) -> [String] {
        contacts.compactMap { r -> String? in
            guard let raw = r.contactFormURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !Reachability.isSocialOnly(raw),
                  !VenueContactGuard.looksLikeVenue(formURL: raw, venue: venue),
                  // #1636: nor a press or media page, the same rule the email path applies to a
                  // "press@" address (#722/#635). The venue guard above cannot cover this: the live case
                  // is a press office on a domain that is not this show's room at all.
                  !PressContactGuard.looksLikePressContact(formURL: raw),
                  let url = URL(string: raw), url.scheme != nil else { return nil }
            return raw
        }
    }

    // #4357 slice G2: the show members the card reads, moved from `Prospect` with their comments.
    // A day of this run Dan cannot work, that he has NOT waved through. This is the one every gate asks:
    // it keeps the show out of the Prep run (no money is spent drafting a show he cannot shoot) and out
    // of the send (a conflict can turn up AFTER the draft exists, which a prep-only gate would miss).
    var hasUnclearedConflict: Bool { conflictOpen }

    // #1501: which night of this show's run the clash is on. Read off the stored key and this show's own
    // date, so the pill and the sentence below are two renderings of ONE decision rather than two rules.
    var conflictScope: ConflictScope? {
        ConflictScope.of(blockedDate: conflictKey.flatMap { BlockedCalendar.Day(key: $0) }?.date,
                         performanceDate: performanceDate)
    }

    // What Dan reads on the row: "You blocked Nov 14 (Vacation)." / "You're already shooting X on Nov 14."
    // Composed from the key, never stored, so it can never be a stale quotation of older copy.
    //
    // #1501: and framed by WHICH night of the run is blocked, because under a date-group header the old
    // sentence read as a claim about that header's date even when the clash was a week later.
    var conflictNote: String? {
        guard let day = conflictKey.flatMap({ BlockedCalendar.Day(key: $0) }) else { return nil }
        return day.reason(scope: conflictScope ?? .thisNight)
    }

    var showSummaryAbsence: ShowSummaryAbsence? {
        showSummaryAbsentReasonRaw.flatMap(ShowSummaryAbsence.init(rawValue:))
    }

    var reachabilityEmptyReason: Reachability.EmptyReason? {
        reachabilityEmptyReasonRaw.flatMap(Reachability.EmptyReason.init(rawValue:))
    }

    func contactRouteForScoring(now: Date) -> ContactRoute {
        if Reachability.probeIsStale(probedAt: reachabilityProbedAt, now: now) { return .unchecked }
        // Deliberately the STORED verdict, not `reachabilityResultAsHeld` which the badge reads.
        //
        // #2664 briefly made this follow the badge, on the reasoning that a card saying "No email found"
        // beside a score still paying route points is a contradiction. Dan's call, 2026-08-13, on being
        // shown that this went further than the decision he actually made: the badge was what he chose,
        // and ranking stays tied to what the paid check CONCLUDED.
        //
        // The two questions really are different, which is why they may answer differently here. The badge
        // asks "can I reach this show right now", and a contact deleted by hand changes that. The score
        // asks "what did the research find", and a hand delete is not a research finding: the score moves
        // when a re-check moves it. Staleness is still shared, so they cannot disagree about whether an
        // answer is CURRENT, which was #1648's point and is untouched.
        return ContactRoute(probeResult: reachabilityResult)
    }

    // #2052: a written email with no subject line. The one definition of that state, read by the send
    // predicate (Recipient.isSendablePending) and by the note beside the greyed Send button, so what
    // holds the send and what explains it can never be two different rules.
    //
    // It asks about a DRAFT, not about the show: a show with no draft at all has no subject because it
    // has no email yet, and treating that as missing would make every un-prepped contact unsendable and
    // change what the whole queue says about who is reachable.
    var draftIsMissingSubject: Bool {
        draftBody != nil && (draftSubject ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

// #4364 (plan v7 Phase 4b(e)): a stored organisation answer as the ledger reads it, or nil for one whose verdict this
// build cannot read. One flattening for the ledger's own boundary (`QueueModel.inheritedAnswers`) and the queue
// engine's patched ledger (`PatchableAnswerLedger`), over the live model and the engine's retained record alike.
extension OrgAnswerLedger.Answer {
    init?(_ row: some OrgAnswerFacts) {
        guard let result = row.result else { return nil }
        self.init(orgKey: row.orgKey, result: result, probedAt: row.probedAt, presenterName: row.presenterName,
                  emails: row.foundEmails)
    }
}
