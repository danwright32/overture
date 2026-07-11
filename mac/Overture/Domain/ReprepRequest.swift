import Foundation

// #367: what Dan asked for when he clicked "Re-prep" on a prospect, either from the per-prospect
// picker or the bulk action. Both share this one type so the gating logic below lives in exactly
// one place.
enum ReprepMode: Sendable {
    case draftOnly
    case contactsOnly
    case both
}

enum ReprepRequest {
    // #733: guard against repeatedly re-prepping the same prospect. 24 hours from when a Prep run
    // last actually served this prospect (a normal fresh draft, or a served re-prep), simple and
    // predictable rather than tied to the Prep run cadence itself.
    static let cooldown: TimeInterval = 86400

    static func isInCooldown(lastServedAt: Date?, now: Date) -> Bool {
        guard let lastServedAt else { return false }
        return now.timeIntervalSince(lastServedAt) < cooldown
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
            if draftAllowed { p.reprepDraftRequested = true }
            return draftAllowed
        case .contactsOnly:
            p.reprepContactsRequested = true
            return false
        case .both:
            if draftAllowed { p.reprepDraftRequested = true }
            p.reprepContactsRequested = true
            return draftAllowed
        }
    }
}
