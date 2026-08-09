import Foundation

// #367: what Dan asked for when he clicked "Re-prep" on a prospect, either from the per-prospect
// picker or the bulk action. Both share this one type so the gating logic below lives in exactly
// one place.
enum ReprepMode: Sendable, Equatable {
    case draftOnly
    case contactsOnly
    case both
}

enum ReprepRequest {
    // #1940: is a Prep run going to rewrite this show? The two flags are independent halves of one
    // request, and three surfaces now ask that question of them (the "Re-prep queued" badge, the control
    // it disables, and the Review stage a queued re-prep takes a show out of). One definition rather than
    // the same `||` written three times, so a third flag added later cannot reach two of them and miss the
    // third.
    static func isQueued(draftRequested: Bool, contactsRequested: Bool) -> Bool {
        draftRequested || contactsRequested
    }

    // #733: guard against repeatedly re-prepping the same prospect. 24 hours from when a Prep run
    // last actually served this prospect (a normal fresh draft, or a served re-prep), simple and
    // predictable rather than tied to the Prep run cadence itself.
    static let cooldown: TimeInterval = 86400

    // #885: what Dan is asked before re-prepping something that was prepped recently. The type that
    // decides there IS a cooldown should also say so. Built inline in an alert closure before.
    //
    // A prospect never re-prepped has no time to state, and must not read "re-prepped ." with a blank
    // where the time should be.
    static func confirmMessage(lastServedAt: Date?, now: Date) -> String {
        guard let lastServedAt else { return "Redo it anyway?" }
        return "This was re-prepped \(PrepStatus.relative(from: lastServedAt, to: now)). Redo it anyway?"
    }

    static func isInCooldown(lastServedAt: Date?, now: Date) -> Bool {
        guard let lastServedAt else { return false }
        return now.timeIntervalSince(lastServedAt) < cooldown
    }

    // #2007, Dan's decision 2: re-prep IS offered on an email he wrote himself, and it asks first,
    // because his own words are the one thing here that cannot be got back.
    static let handWrittenConfirmMessage =
        "This replaces the email you wrote yourself with an AI draft. Replace it?"

    // What to ask before this re-prep runs, or nil to go straight ahead. ONE decision covering both
    // reasons a re-prep confirms, so a click can never raise two alerts in a row (which is not a warning,
    // it is a habit of clicking through) and the caller has no rule of its own to keep in step.
    //
    // Losing hand-written text outranks the cooldown: the cooldown protects a Prep run's cost, this
    // protects work only Dan can redo. A contacts-only request never touches the words, so it is never
    // warned about on that ground.
    static func confirmation(mode: ReprepMode, writtenByDan: Bool,
                             lastServedAt: Date?, now: Date) -> String? {
        if writtenByDan && mode != .contactsOnly { return handWrittenConfirmMessage }
        guard isInCooldown(lastServedAt: lastServedAt, now: now) else { return nil }
        return confirmMessage(lastServedAt: lastServedAt, now: now)
    }

    // Sets the prospect's re-prep flags for the requested mode. Gates the DRAFT-affecting half on
    // `sentAt == nil` (#367 red-team finding 3): a multi-recipient show can have one recipient
    // already sent while the prospect itself is still `.approved` (SendService keeps it approved
    // until every recipient is sendable/sent), so redrafting the shared body after a partial send
    // would silently create two different pitches for the same show. Contacts-only is never
    // restricted by send state, it never touches the text anyone already received.
    // Returns whether the draft-affecting half was actually granted, so a bulk caller can summarize
    // how many prospects got the full request versus a narrowed one.
    @discardableResult
    static func apply(_ mode: ReprepMode, to p: Prospect) -> Bool {
        let draftAllowed = p.sentAt == nil
        switch mode {
        case .draftOnly:
            if draftAllowed { grantDraft(to: p) }
            return draftAllowed
        case .contactsOnly:
            p.reprepContactsRequested = true
            return false
        case .both:
            if draftAllowed { grantDraft(to: p) }
            p.reprepContactsRequested = true
            return draftAllowed
        }
    }

    // #2007: granting a redraft RELEASES a hand-written draft to the run. The marker is what makes
    // PrepImporter refuse to overwrite this text, so leaving it set here would spend a whole Prep run
    // whose draft is then discarded on arrival: a request that reads as granted and silently does
    // nothing. Only on the branch where the redraft is actually allowed, so a request the send gate
    // refuses leaves his words protected rather than exposed to the next unrelated run.
    private static func grantDraft(to p: Prospect) {
        p.reprepDraftRequested = true
        p.draftWrittenByDan = false
    }
}
