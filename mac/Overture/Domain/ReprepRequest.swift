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

    // MARK: what to CALL it (#2548)
    //
    // Dan, on a show he had prepped by hand: "we should hide re-prep if it was a manual prep or rename it
    // since it would be the first prep." The card said "Written by you" and the control beside it said
    // "Re-prep", with no Prep run having ever served that show.
    //
    // Renamed rather than hidden, because hiding takes away "Find contacts only", which is the most useful
    // thing on a hand-prepped card: Dan typed one address himself and a run could find the others.
    //
    // The rule lives here, beside the offer decision, rather than as an `if` inside each surface. Four of
    // them say the word (the menu, the queued badge, the confirm's title and its button) and a fifth says
    // it in the acknowledgement afterwards; spelled out at each one they would eventually disagree on a
    // single card (L16).

    // Has any Prep run served this show? `draftWrittenByDan` alone cannot answer it: Dan can hand-prep and
    // then press "Find contacts only", which finds contacts without touching his text, so the flag stays
    // true while a run really has run. `reprepLastServedAt` is stamped by PrepImporter whenever a run
    // serves the show, so the two together mean "Dan wrote the first and only draft this show has had".
    static func isFirstPrep(writtenByDan: Bool, lastServedAt: Date?) -> Bool {
        writtenByDan && lastServedAt == nil
    }

    static func verb(writtenByDan: Bool, lastServedAt: Date?) -> String {
        isFirstPrep(writtenByDan: writtenByDan, lastServedAt: lastServedAt) ? "Prep" : "Re-prep"
    }

    static func gerund(writtenByDan: Bool, lastServedAt: Date?) -> String {
        isFirstPrep(writtenByDan: writtenByDan, lastServedAt: lastServedAt) ? "Prepping" : "Re-prepping"
    }

    static func menuLabel(writtenByDan: Bool, lastServedAt: Date?) -> String {
        verb(writtenByDan: writtenByDan, lastServedAt: lastServedAt)
    }

    // Both spellings are written out as LITERALS rather than composed from `verb`, deliberately. The copy
    // inventory exists so a PR that changes the app's wording shows that change in the words Dan will read;
    // composed here, these five sentences appeared in it as `"\(verb(writtenByDan:…)) queued"`, which is a
    // line of Swift. `everySurfaceSpellsItTheSameWayOnOneShow` is what keeps the pairs in step with `verb`.
    static func confirmTitle(writtenByDan: Bool, lastServedAt: Date?) -> String {
        isFirstPrep(writtenByDan: writtenByDan, lastServedAt: lastServedAt)
            ? "Prep this show?" : "Re-prep this show?"
    }

    static func queuedBadge(writtenByDan: Bool, lastServedAt: Date?) -> String {
        isFirstPrep(writtenByDan: writtenByDan, lastServedAt: lastServedAt)
            ? "Prep queued" : "Re-prep queued"
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
    // #2014: what a BULK sweep may ask of one row, which is not always what the menu asked for.
    //
    // The single-show control confirms before replacing hand-written text (#2007), and a bulk action
    // cannot: a dialog per row is not a bulk action. So the destructive half is withheld instead. Losing
    // words Dan typed is the one unrecoverable outcome on this path, because `originalDraftBody` is only
    // populated when an AI draft is EDITED, so a wholly hand-written draft leaves nothing to fall back to.
    //
    // The SAFE half still happens: finding contacts never touches the text, so withholding that too would
    // make the protection cost him something he never asked to give up. nil means there is nothing left
    // for this row to be asked, which is a draft-only sweep meeting his own email.
    //
    // Pure and here rather than at the call site, so every case can be produced by a fixture and the rule
    // sits beside `apply`, which is what performs it.
    static func bulkMode(_ mode: ReprepMode, writtenByDan: Bool) -> ReprepMode? {
        guard writtenByDan else { return mode }
        switch mode {
        case .contactsOnly: return .contactsOnly
        case .both: return .contactsOnly
        case .draftOnly: return nil
        }
    }

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
