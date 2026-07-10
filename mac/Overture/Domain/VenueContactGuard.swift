import Foundation

// #388: a lightweight, heuristic backstop for the runbook's own "never the venue" rule (#368). Not
// a full curated venue-to-domain map (that's #342 territory); just enough to catch the exact live
// bug: an address whose domain matches the venue's own name or its VenueDisplay-resolved parent
// building. Exact match on the domain's second-level label only (not a loose substring check), plus
// a minimum slug length, to keep false positives rare on a short or generic venue name.
enum VenueContactGuard {
    private static let minimumSlugLength = 5

    static func looksLikeVenue(email: String?, venue: String?) -> Bool {
        guard let email, !email.isEmpty, let venue, !venue.isEmpty,
              let domainCore = secondLevelDomain(of: email) else { return false }
        let display = VenueDisplay.resolve(venue)
        let candidates = [display.hall, display.parent].compactMap { $0 }.map(slug)
        return candidates.contains { $0.count >= minimumSlugLength && $0 == domainCore }
    }

    // The domain's second-level label: "carnegiehall" from "carnegiehall.org" or from
    // "mail.carnegiehall.org" alike (the label right before the last dot-separated component).
    private static func secondLevelDomain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].lowercased()
        let parts = domain.split(separator: ".")
        guard parts.count >= 2 else { return parts.first.map(String.init) }
        return String(parts[parts.count - 2])
    }

    private static func slug(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
