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

    // #2629: a ROUTE, not only an address. A contact form on the producer's own site and a social profile
    // Dan will DM are both ways in he uses by hand, and the Review card tells him to add one on exactly
    // the shows that have nothing else. Which of the two it is changes only what the informational flags
    // can say; the create/resume/blocked decision is one rule for both, keyed on the recipient handle,
    // because "this route already belongs to somebody on this show" means the same thing either way.
    static func evaluate(route: ManualContactRoute, existingRecipients: [Recipient],
                         venue: String?) -> Result {
        switch route {
        case .email(let address):
            return evaluate(email: address, existingRecipients: existingRecipients, venue: venue)
        case .link(let url):
            let handle = Recipient.makeId(email: nil, formURL: url) ?? url
            // A link cannot share an email domain with anybody, so `sharesOrgWith` is genuinely nil here
            // rather than unchecked. The venue flag is asked through the SAME guard the card filters
            // displayed forms with, so a link the card would hide cannot come back flagged as fine.
            let looksLikeVenue = VenueContactGuard.looksLikeVenue(formURL: url, venue: venue)
            if let match = existingRecipients.first(where: { $0.id == handle }) {
                return Result(action: action(for: match), sharesOrgWith: nil,
                              looksLikeVenue: looksLikeVenue)
            }
            return Result(action: .create, sharesOrgWith: nil, looksLikeVenue: looksLikeVenue)
        }
    }

    static func evaluate(email: String, existingRecipients: [Recipient], venue: String?) -> Result {
        let canonical = ReplyDetection.email(from: email)
        let emailDomain = domain(of: canonical)

        if let match = existingRecipients.first(where: { $0.id == canonical }) {
            return Result(action: action(for: match), sharesOrgWith: nil,
                          looksLikeVenue: looksLikeVenue(emailDomain, venue: venue))
        }

        let orgMatch = existingRecipients.first { !emailDomain.isEmpty && domain(of: $0.id) == emailDomain }
        return Result(action: .create, sharesOrgWith: orgMatch?.id,
                      looksLikeVenue: looksLikeVenue(emailDomain, venue: venue))
    }

    // #2629: what an existing match means, in ONE place, so the address arm and the link arm cannot
    // disagree about when re-adding somebody resumes them and when it is refused.
    private static func action(for match: Recipient) -> Action {
        let bookedElsewhere = match.sendState == .suppressed && match.suppressionReason == .bookedElsewhere
        let removedByDan = match.sendState == .suppressed && match.suppressionReason == .removedByDan
        let declinedSuppression = match.sendState == .suppressed && match.suppressionReason == .declined
        if match.resolution == .booked || bookedElsewhere {
            return .blocked(existingId: match.id)
        }
        // #2112: a contact closed out for never answering resumes like a soft decline. Nothing was
        // refused, so re-adding the address is Dan trying again, not overriding a "no".
        if removedByDan || declinedSuppression || match.resolution == .declinedSoft
            || match.resolution == .declinedHard || match.resolution == .neverHeardBack {
            return .resume(existingId: match.id)
        }
        return .blocked(existingId: match.id)   // still active and unresolved
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
