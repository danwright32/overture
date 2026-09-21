import Foundation

// #4116: the one place a listing address is folded before two of them are compared for identity.
//
// WHY IT EXISTS. `ScoutService.matchByStableSource` joins a stored row to an incoming listing on the
// listing URL plus the date plus the folded venue, and `matchByAnyRunURL` joins on any shared run member
// URL. Both compared raw strings, so one page addressed two ways was two pages and the arm that exists
// to recognise a second billing of one show missed the cheapest possible near miss. Measured on the live
// store 2026-09-21: `https://www.kaufmanmusiccenter.org/mch/event/orli-shaham-in-claras-hands` and the
// same address with a trailing slash are two rows for one concert, one venue, one night, minted eight
// weeks apart.
//
// WHY ONLY THE TRAILING SLASH. Four rules were scored over the same corpus (1,312 rows carrying a
// listing URL) by counting the pairs each would newly make share a URL on one night:
//
//   trailing slash   +4 pairs, and all four are one show billed two ways
//   host lowercased  +0
//   scheme to https  +0
//   `www.` dropped   +0
//
// Each of the other three is a judgement carrying a cost (a path is case sensitive on some servers; two
// schemes can be two sites), and none of them buys a single join on today's store, so none is adopted.
// This paragraph is the record of what was measured rather than overlooked (L308), and the measurement
// is re-takeable: it is the pair count over `ZSOURCELISTINGURL` grouped by each fold.
//
// The QUERY is deliberately untouched. OvationTix's `performanceId` IS the identity of a night, so
// stripping the query wholesale would fuse every night of a run onto one row, which is the opposite of
// what this milestone is for.
//
// FOLDED AT READ TIME, on both sides, never at write time. Every row already in the store carries
// whatever spelling it was written with, so a fold applied only to new writes would reach nothing that
// already exists (L389).
enum ListingURL {
    // Removes exactly one trailing slash from the PATH, leaving the query and the fragment alone. A
    // string that does not end its path in a slash comes back unchanged, so this is safe to apply to
    // anything, including a value that is not a URL at all.
    static func fold(_ raw: String) -> String {
        let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? raw.endIndex
        let path = raw[raw.startIndex..<cut]
        guard path.hasSuffix("/") else { return raw }
        let trimmed = path.dropLast()
        // Refuse where the slash is structural rather than trailing: `https://` folds to `https:/`,
        // which names a different thing and is never what an address meant. The test asserts this, since
        // an over eager fold is how a normalisation joins two pages that are not one (L273).
        guard let last = trimmed.last, last != "/", last != ":" else { return raw }
        return String(trimmed) + String(raw[cut...])
    }

    // Whether two addresses name one listing. Both sides are folded, which is the whole point: a
    // comparison that folds one side only is the same defect wearing a helper's name.
    static func sameListing(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return fold(a) == fold(b)
    }

    // The folded forms of a set of addresses, for the arms that ask whether two runs share any member.
    static func foldedSet(_ urls: [String]) -> Set<String> {
        Set(urls.map(fold))
    }
}
