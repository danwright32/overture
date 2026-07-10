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
    // Sets the prospect's re-prep flags for the requested mode. Gates the DRAFT-affecting half on
    // `sentAt == nil` (#367 red-team finding 3): a multi-recipient show can have one recipient
    // already sent while the prospect itself is still `.approved` (SendService keeps it approved
    // until every recipient is sendable/sent), so redrafting the shared body after a partial send
    // would silently create two different pitches for the same show. Contacts-only is never
    // restricted by send state, it never touches the text anyone already received.
    static func apply(_ mode: ReprepMode, to p: Prospect) {
        let draftAllowed = p.sentAt == nil
        switch mode {
        case .draftOnly:
            if draftAllowed { p.reprepDraftRequested = true }
        case .contactsOnly:
            p.reprepContactsRequested = true
        case .both:
            if draftAllowed { p.reprepDraftRequested = true }
            p.reprepContactsRequested = true
        }
    }
}
