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
    //
    // #1620 adds two reductions ON TOP, and they live HERE rather than in VenueNormalization on purpose:
    // normalizeForKey builds every prospect's natural key, so widening it would re-key the whole live
    // store, which is a migration (NaturalKeyVenueMigration), not a gate fix. This fold is a comparison,
    // and it is thrown away after the verdict.
    //
    //   - a parenthetical qualifier: "The Church of St. Mary the Virgin (Times Square)" is the same room
    //     as "The Church of St. Mary the Virgin", and counting it twice let a single-room company clear
    //     the venue count.
    //   - a leading "the": "The Soldiers' and Sailors' Monument" is that same monument. Hudson Classical
    //     Theater Company plays it, spelled both ways, and nothing else.
    static func key(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var folded = VenueNormalization.normalizeForKey(raw)
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        folded = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.isEmpty ? nil : folded
    }

    // Every arm must hold, and each catches what the others miss.
    //
    // The ROOM-NAME arm alone is not enough: it admits FRIGID New York, which rents Under St Marks to 40
    // different companies and whose name is never itself a venue string, so one lookup would be stamped
    // on 40 unrelated productions.
    //
    // The VENUE-COUNT arm alone is not enough either: Abrons Arts Center presents under five venue
    // spellings, so it clears the count while plainly being a house.
    // `promoted` holds folded keys Dan has confirmed by hand are producers. It relaxes the VENUE-COUNT
    // arm and the name-CONTAINMENT arm, and never the EQUALITY arm. That split is the honest one:
    //
    //   - an equal name means the presenter field literally holds a venue string, so there is no
    //     organisation there to promote, only the room, and his standing rule is that a room's own
    //     address is never a real contact.
    //   - containment is strong evidence about names, not proof about the organisation. The Metropolitan
    //     Opera produces its own work at the Metropolitan Opera House, and promotion is exactly the
    //     escape hatch for that case, so a name overlap must not be the one thing his own judgment
    //     cannot overrule.
    static func qualifies(_ presenter: String, among shows: [Show],
                          overrides: ProducerOverrides = .none) -> Bool {
        guard let presenterKey = key(presenter) else { return false }
        guard !isVenueBrand(presenterKey, venueKeys: venueKeys(of: shows), overrides: overrides)
        else { return false }
        if overrides.promoted.contains(presenterKey) { return true }
        return distinctVenues(presenterKey, among: shows).count >= 2
    }

    // #1702: "this presenter name is really the building's own brand", named once and shared, because a
    // second copy of this judgment is how the two halves drift apart. The gate above asks it to refuse a
    // shared reachability answer; HistoryMatch asks it to refuse a fuzzy name match, since a brand every
    // show in the building shares lets ONE past record raise a question on all of them (#1693 hit 18
    // Carnegie Hall cards that way).
    //
    // Promotion relaxes the containment arm and never the equality arm, exactly as qualifies always did:
    // a presenter spelled precisely like a room IS the room, and there is no organisation there to
    // promote. Takes an already-folded key, so callers that fold once for many lookups pay for it once.
    // Takes the corpus as its FOLDED VENUE KEYS rather than its shows, because both arms only ever ask
    // about venue strings, and the live store's 700-odd rows carry 114 distinct rooms between them. A
    // caller asking about many presenters folds the venues once instead of per question.
    static func isVenueBrand(_ presenterKey: String, venueKeys: Set<String>,
                             overrides: ProducerOverrides = .none) -> Bool {
        if venueKeys.contains(presenterKey) { return true }
        // #1719: the other direction, and it is tested BEFORE promotion on purpose. A key in both lists
        // should never reach here (ProducerOverrideEditing keeps them mutually exclusive), but if one
        // ever does, the refusing answer is the safe one: this gate's standing rule is to fail toward
        // "no key, pay again" and never toward a shared answer.
        if overrides.demoted.contains(presenterKey) { return true }
        if overrides.promoted.contains(presenterKey) { return false }
        return venueKeys.contains { namesTheSameRoom(presenterKey, $0) }
    }

    static func venueKeys(of shows: [Show]) -> Set<String> {
        Set(shows.compactMap { key($0.venue) })
    }

    // #1720 (milestone 34 Phase 3): the same verdicts, named and handed OUT of the app, so the Prep run
    // stops deciding for itself which organisation is the building. The run named Henry Street Settlement,
    // put it in a search query, and concluded nothing existed without ever fetching henrystreet.org
    // (#1681); the waterfall had no step for an organisation named in a listing's BODY rather than in a
    // field, because it had no way to tell one from the house.
    //
    // Deliberately NOT a new rule. Every key here comes from a verdict this gate already reaches, and the
    // runbook is told to look names up rather than judge them, because the English version of this
    // judgment (compare the org's domain against the host venue's) was refuted on five live rows: Carnegie
    // Hall Citywide at Madison Square Park, Bryant Park twice and Historic Richmond Town, and NYO2 in
    // Santo Domingo, all served from carnegiehall.org with a host venue whose domain is not. A second copy
    // is what #1702 exists to prevent.
    struct House: Codable, Equatable, Sendable {
        // The gate's own folded key, for an exact lookup.
        let key: String
        // One readable spelling of the same room, for a run comparing against a name it read on a page.
        // Both, rather than either alone: a folded key asks the run to fold, which it can get wrong, and a
        // readable name alone cannot collapse two spellings of one room into one entry. A missed match is
        // the expensive direction (the run visits the house and may offer its address), so it gets two
        // ways to hit.
        let name: String
    }

    // The whole house list for a corpus: every venue string in it, every presenter its own venue-brand
    // arms refuse, and every house Dan demoted by hand. Sorted by key, so one store always writes one
    // byte-identical file and two runs differ in the diff only when the store really changed.
    //
    // Promotion is inherited from isVenueBrand rather than re-decided: a promoted name that only reached
    // the list through CONTAINMENT comes off it (the Metropolitan Opera produces its own work at the
    // Metropolitan Opera House), and one spelled exactly like a room stays on it, because a presenter
    // spelled precisely like a room IS the room and there is no organisation there to promote.
    static func houses(shows: [Show], overrides: ProducerOverrides = .none) -> [House] {
        let venueKeys = venueKeys(of: shows)
        var keys = venueKeys
        for presenter in Set(shows.compactMap { $0.presenter }) {
            guard let presenterKey = key(presenter) else { continue }
            if isVenueBrand(presenterKey, venueKeys: venueKeys, overrides: overrides) {
                keys.insert(presenterKey)
            }
        }
        // Dan's own corrections last, and unconditionally: a key he has demoted is a house whatever the
        // automatic arms concluded, which is the whole point of the override (FRIGID New York rents one
        // room to 40 companies and is named in no venue string, so nothing else reaches it).
        keys.formUnion(overrides.demoted)

        let names = readableNames(in: shows)
        return keys.sorted().map { House(key: $0, name: names[$0] ?? $0) }
    }

    // One readable spelling per key, chosen from every venue and presenter string in the corpus. The
    // spelling is the room's OWN name (VenueNormalization.keyName), so a venue string that carries its
    // parent building names the room and the parent reaches the list on its own rows.
    //
    // Shortest wins, ties broken alphabetically, purely so the choice is deterministic: candidates for one
    // key differ only in case, punctuation and a leading "the", and an order-dependent pick would make two
    // identical runs write two different files. A key with no spelling left anywhere in the corpus (a
    // correction Dan made against a store that has since changed) falls back to showing the key itself in
    // `houses` above, which is honest; dropping it would silently discard his correction.
    private static func readableNames(in shows: [Show]) -> [String: String] {
        var names: [String: String] = [:]
        for raw in shows.flatMap({ [$0.venue, $0.presenter] }).compactMap({ $0 }) {
            guard let folded = key(raw) else { continue }
            let candidate = VenueNormalization.keyName(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            guard let existing = names[folded] else { names[folded] = candidate; continue }
            if candidate.count < existing.count
                || (candidate.count == existing.count && candidate < existing) {
                names[folded] = candidate
            }
        }
        return names
    }

    // The same verdict for a whole corpus, computed once. Built for the matcher, which asks it per ROW:
    // re-walking every show for every row would be several hundred thousand string comparisons on the
    // live store, and the answer never changes within a run.
    struct VenueBrands: Equatable, Sendable {
        private let brandKeys: Set<String>

        // No corpus, no exclusions. The default for every caller that has no store in hand (a unit test,
        // an importer), so this can never silently start suppressing matches somewhere that never opted in.
        static let none = VenueBrands(brandKeys: [])

        private init(brandKeys: Set<String>) { self.brandKeys = brandKeys }

        init(shows: [Show], overrides: ProducerOverrides = .none) {
            let venueKeys = ProducerGate.venueKeys(of: shows)
            var keys = Set<String>()
            for presenter in Set(shows.compactMap { $0.presenter }) {
                guard let key = ProducerGate.key(presenter), !keys.contains(key) else { continue }
                if ProducerGate.isVenueBrand(key, venueKeys: venueKeys, overrides: overrides) {
                    keys.insert(key)
                }
            }
            brandKeys = keys
        }

        func contains(_ presenter: String?) -> Bool {
            guard let presenter, let key = ProducerGate.key(presenter) else { return false }
            return brandKeys.contains(key)
        }
    }

    // Equality is the first arm of isVenueBrand above: a name spelled exactly like a venue in the set is
    // that room, whatever else it also does.
    //
    // A name that CONTAINS, or IS CONTAINED IN, a venue somewhere in the set is that venue's own brand.
    //
    // LIVE-STORE-CLAIM verified=2026-07-28 measure="rows presented by Carnegie Hall Presents, the gate's single biggest admission before #1620"
    // #1620: equality alone missed the commonest form a house takes, its own presenting brand. Carnegie
    // Hall Presents is Carnegie Hall; Stern, Zankel, Weill and Resnick are four rooms inside that one
    // building, so the venue count read a house as a well travelled producer and the name never matched
    // "Carnegie Hall" exactly. 25 rows on the live store, and Dan will not write to an @carnegiehall
    // address: "I'm never going to use an @carnegiehall email."
    //
    // LIVE-STORE-CLAIM verified=2026-07-28 measure="presenters the reverse containment arm refuses, each named inside a venue string in the store"
    // The reverse direction catches the other spelling of the same relationship, a presenter named for
    // the building inside a venue string that names the room ("Weill Recital Hall at Carnegie Hall").
    // Measured on the live store: it refuses The 52nd Street Project, Spit&Vigor and the Royal
    // Concertgebouw, each of which runs the room it is named after, and nothing else.
    private static func namesTheSameRoom(_ presenterKey: String, _ venueKey: String) -> Bool {
        containsAsWords(presenterKey, venueKey) || containsAsWords(venueKey, presenterKey)
    }

    // Whole words only, and never on a single-word name. Both guards are load-bearing: The Cell and The
    // Tank fold to the single words "cell" and "tank" on the live store, and a bare substring test would
    // then read a hypothetical Think Tank Theatre as that venue's own brand and refuse it forever.
    //
    // #1687 shares it rather than copying it: the card asks the same question of a different pair (does
    // this show's TITLE already name its presenter, so drawing the name again would only repeat the line
    // above), and both guards are load-bearing there too. A second copy is how the two drift.
    static func containsAsWords(_ haystack: String, _ needle: String) -> Bool {
        guard needle.split(separator: " ").count >= 2, haystack != needle else { return false }
        for range in haystack.ranges(of: needle) {
            let startsAtWord = range.lowerBound == haystack.startIndex
                || haystack[haystack.index(before: range.lowerBound)] == " "
            let endsAtWord = range.upperBound == haystack.endIndex
                || haystack[range.upperBound] == " "
            if startsAtWord && endsAtWord { return true }
        }
        return false
    }

    private static func distinctVenues(_ presenterKey: String, among shows: [Show]) -> Set<String> {
        Set(shows.compactMap { show -> String? in
            guard key(show.presenter) == presenterKey else { return nil }
            return key(show.venue)
        })
    }
}
