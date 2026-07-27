import Foundation

// #1593 (milestone 32 Phase 0.2): may one reachability answer be reused across every show from the same
// presenter? Only when the data proves the presenter is a PRODUCER rather than a room that rents itself
// out. Getting this wrong permissively is the worst outcome the feature can produce, so the rule fails
// toward "no key, pay again" and never toward a shared answer.
enum ProducerGate {

    struct Show: Equatable {
        let presenter: String?
        let venue: String?
    }

    // Folded the same way on both sides, so a presenter string and a venue string are compared like for
    // like. VenueNormalization.normalizeForKey reduces a venue to its own name (first clause) and folds
    // the punctuation variance, which is exactly the comparison this gate needs.
    static func key(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = VenueNormalization.normalizeForKey(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return folded.isEmpty ? nil : folded
    }

    // Both arms must hold, and each catches what the other misses.
    //
    // The ROOM-NAME arm alone is not enough: it admits FRIGID New York, which rents Under St Marks to 40
    // different companies and whose name is never itself a venue string, so one lookup would be stamped
    // on 40 unrelated productions.
    //
    // The VENUE-COUNT arm alone is not enough either: Abrons Arts Center presents under five venue
    // spellings, so it clears the count while plainly being a house.
    // `promoted` holds folded keys Dan has confirmed by hand are producers. It relaxes the VENUE-COUNT
    // arm only. The room-name arm is never relaxed: his standing rule is that a room's own address is
    // never a real contact, so no promotion, mistaken or otherwise, can fan a house's answer outward.
    static func qualifies(_ presenter: String, among shows: [Show],
                          promoted: Set<String> = []) -> Bool {
        guard let presenterKey = key(presenter) else { return false }
        guard !isAlsoAVenue(presenterKey, among: shows) else { return false }
        if promoted.contains(presenterKey) { return true }
        return distinctVenues(presenterKey, among: shows).count >= 2
    }

    // A name that appears anywhere in the set as a venue is a house, whatever else it also does.
    private static func isAlsoAVenue(_ presenterKey: String, among shows: [Show]) -> Bool {
        shows.contains { key($0.venue) == presenterKey }
    }

    private static func distinctVenues(_ presenterKey: String, among shows: [Show]) -> Set<String> {
        Set(shows.compactMap { show -> String? in
            guard key(show.presenter) == presenterKey else { return nil }
            return key(show.venue)
        })
    }
}
