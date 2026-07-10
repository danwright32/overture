import Foundation
import SwiftData

// #726: a narrow safety net for #369's grouping, the SAME real-world performance somehow still
// producing two separate Prospect rows (grouping's title/venue/date matching didn't merge them).
// Fires only when contact, venue, AND date all agree, deliberately narrower than "this contact is
// pitched elsewhere soon": a shared contact at a genuinely DIFFERENT venue (e.g. a touring act's
// shared booking-agency inbox pitching two different upcoming shows) is legitimate and never
// flagged. Unlike VenueContactGuard/PressContactGuard (pure functions), this needs a ModelContext
// since it looks across OTHER prospects, not just this recipient's own fields.
enum DuplicateContactGuard {
    private static let gapDays = 3  // mirrors RunGrouping's own window (#369)

    // #Predicate cannot call .lowercased() inside its closure, so the email/venue comparison is
    // done in plain Swift after an unfiltered fetch, not via a predicate.
    static func looksLikeDuplicate(email: String?, venue: String?, performanceDate: String?,
                                   excludingProspectKey: String, in context: ModelContext) -> Bool {
        guard let email, !email.isEmpty, let venue, !venue.isEmpty, let performanceDate else { return false }
        let targetEmail = canon(email)
        let targetVenue = canon(venue)
        guard let allRecipients = try? context.fetch(FetchDescriptor<Recipient>()) else { return false }
        return allRecipients.contains { r in
            guard let rEmail = r.email, canon(rEmail) == targetEmail,
                  let p = r.prospect, p.naturalKey != excludingProspectKey, !p.isClosed,
                  let pVenue = p.venue, canon(pVenue) == targetVenue,
                  let otherDate = p.performanceDate,
                  let gap = EasternDate.daysUntil(from: otherDate, to: performanceDate)
            else { return false }
            return abs(gap) <= gapDays
        }
    }

    private static func canon(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }
}
