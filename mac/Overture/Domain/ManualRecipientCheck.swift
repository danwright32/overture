import Foundation

// The manual add-a-contact check (#399): before creating a new Recipient by hand, decide whether
// the typed email already belongs to someone on this show (blocked, or resumable if pursuit had
// stopped), and surface two ALWAYS-informational, never-blocking flags: a shared domain with
// another existing contact, and a domain that looks like the venue's own. Pure and SwiftData-free
// so every branch is unit tested without a ModelContext, mirroring ConversationReminder/FollowUp's
// calculator style. Manual adds are never blocked for the venue/org reasons, only exact-duplicate
// identity blocks, and only when the match is still active or already settled.
enum ManualRecipientCheck {
    enum Action: Equatable {
        case create                        // no conflict, add a fresh Recipient
        case resume(existingId: String)    // matches a contact pursuit had stopped on; resume it
        case blocked(existingId: String)   // matches an already-active or settled contact
    }

    struct Result: Equatable {
        let action: Action
        let sharesOrgWith: String?   // id of another existing recipient on the same domain, if any
        let looksLikeVenue: Bool
    }

    static func evaluate(email: String, existingRecipients: [Recipient], venue: String?) -> Result {
        let canonical = ReplyDetection.email(from: email)
        let emailDomain = domain(of: canonical)

        if let match = existingRecipients.first(where: { $0.id == canonical }) {
            let bookedElsewhere = match.sendState == .suppressed && match.suppressionReason == .bookedElsewhere
            let removedByDan = match.sendState == .suppressed && match.suppressionReason == .removedByDan
            let declinedSuppression = match.sendState == .suppressed && match.suppressionReason == .declined
            let action: Action
            if match.resolution == .booked || bookedElsewhere {
                action = .blocked(existingId: match.id)
            } else if removedByDan || declinedSuppression || match.resolution == .declinedSoft || match.resolution == .declinedHard {
                action = .resume(existingId: match.id)
            } else {
                action = .blocked(existingId: match.id)   // still active and unresolved
            }
            return Result(action: action, sharesOrgWith: nil, looksLikeVenue: looksLikeVenue(emailDomain, venue: venue))
        }

        let orgMatch = existingRecipients.first { !emailDomain.isEmpty && domain(of: $0.id) == emailDomain }
        return Result(action: .create, sharesOrgWith: orgMatch?.id,
                      looksLikeVenue: looksLikeVenue(emailDomain, venue: venue))
    }

    private static func domain(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return String(email[email.index(after: at)...]).lowercased()
    }

    // A heuristic, not a lookup: strips common venue words (the same vocabulary VenueParser uses
    // for the automated importer, so "the venue" means the same thing on both paths), then checks
    // whether any remaining significant word appears in the email's domain. Can false-positive (an
    // unrelated org whose name happens to share a word) or false-negative (a venue whose domain
    // does not resemble its display name). Both are fine: the caller only ever surfaces this as an
    // informational flag, never a block.
    private static func looksLikeVenue(_ domain: String, venue: String?) -> Bool {
        guard !domain.isEmpty, let venue, !venue.isEmpty else { return false }
        let stripped = VenueParser.venueWords.reduce(venue) { result, word in
            result.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        let words = stripped.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        return words.contains { $0.count > 3 && domain.contains($0) }
    }
}
