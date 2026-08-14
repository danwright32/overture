import Foundation

// #388: a lightweight, heuristic backstop for the runbook's own "never the venue" rule (#368). Not
// a full curated venue-to-domain map (that's #342 territory); just enough to catch the exact live
// bug: an address whose domain matches the venue's own name or its VenueDisplay-resolved parent
// building. Exact match on the domain's second-level label only (not a loose substring check), plus
// a minimum slug length, to keep false positives rare on a short or generic venue name.
enum VenueContactGuard {
    private static let minimumSlugLength = 5

    static func looksLikeVenue(email: String?, venue: String?) -> Bool {
        guard let email, !email.isEmpty else { return false }
        return isTheRoomsOwn(domainCore: secondLevelDomain(of: email), venue: venue)
    }

    // #1629: the same question asked of a contact FORM's link. #1626 made a form on the act's own site
    // count as a way through and nothing kept the ROOM's own booking form out of that, so a check that
    // returned the venue's form produced a card pointing Dan straight at the room, against the oldest
    // standing rule in the product (#368).
    //
    // Deliberately the same comparison and not a second copy of it: a rule about "is this the room's
    // own contact" that is spelled one way for an address and another way for a link is a rule that
    // will disagree with itself. Only the domain EXTRACTION differs between the two routes.
    static func looksLikeVenue(formURL: String?, venue: String?) -> Bool {
        guard let formURL, !formURL.isEmpty else { return false }
        // #2612: a social profile puts the identity in the PATH, never the domain: every act on Instagram
        // shares "instagram.com" and is told apart by its handle. The domain comparison below is therefore
        // structurally blind to the ROOM's own account, and since #2612 makes a social handle a route
        // again, that blindness would re-open #368 (a room's own contact is never a real contact) through
        // a side door. Measured: instagram.com/jalopytheatre on a Jalopy Theatre show read as a route.
        //
        // The same comparison, pointed at the identifying half of the URL, which is PressContactGuard's
        // own reasoning for reading a link's path rather than its host.
        if Reachability.isSocialOnly(formURL) {
            return isTheRoomsOwn(domainCore: firstPathComponent(ofURL: formURL), venue: venue)
        }
        return isTheRoomsOwn(domainCore: secondLevelDomain(ofURL: formURL), venue: venue)
    }

    // The handle: "jalopytheatre" from "https://www.instagram.com/jalopytheatre/", slugged the same way a
    // domain label is so the one comparison can take either.
    private static func firstPathComponent(ofURL raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return url.path.split(separator: "/").first.map { slug(String($0)) }
    }

    // The venue side of the comparison, shared by both routes: the hall's own name or its
    // VenueDisplay-resolved parent building, matched EXACTLY against the domain's second-level label,
    // with a minimum slug length so a short or generic room name cannot swallow an unrelated site.
    private static func isTheRoomsOwn(domainCore: String?, venue: String?) -> Bool {
        guard let domainCore, let venue, !venue.isEmpty else { return false }
        let display = VenueDisplay.resolve(venue)
        let candidates = [display.hall, display.parent].compactMap { $0 }.map(slug)
        return candidates.contains { $0.count >= minimumSlugLength && $0 == domainCore }
    }

    // The domain's second-level label: "carnegiehall" from "carnegiehall.org" or from
    // "mail.carnegiehall.org" alike (the label right before the last dot-separated component).
    private static func secondLevelDomain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        return secondLevelDomain(ofHost: String(email[email.index(after: at)...]))
    }

    // The same label taken from a link's host, so "https://www.carnegiehall.org/contact" reduces to
    // "carnegiehall" exactly as an address at that domain does. A string that will not parse as a URL
    // with a host cannot be compared and is never treated as the room's.
    private static func secondLevelDomain(ofURL raw: String) -> String? {
        guard let host = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host else {
            return nil
        }
        return secondLevelDomain(ofHost: host)
    }

    private static func secondLevelDomain(ofHost host: String) -> String? {
        let parts = host.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return parts.first.map(String.init) }
        return String(parts[parts.count - 2])
    }

    private static func slug(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
