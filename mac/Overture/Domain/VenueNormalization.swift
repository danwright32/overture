import Foundation

// #1064: a dedicated venue-normalization pass, DELIBERATELY DISTINCT from VenueDisplay.normalize (which
// is display only and preserves punctuation on purpose). This one folds the formatting variance that
// genuinely denotes the SAME physical venue, so two spellings of one venue produce ONE natural key and
// resolve to ONE curated-map entry. The variance the live-store audit (#1064) proved:
//   - a street address the source page baked into the venue text ("The Cutting Room, 44 East 32nd
//     Street, New York, NY" versus the bare "The Cutting Room"): the exact mechanism behind the six
//     confirmed duplicate prospect pairs,
//   - a comma before a two-letter state code ("Chatham, NJ" versus "Chatham NJ"),
//   - common street-suffix abbreviations ("65th St" versus "65th Street"),
//   - spacing around a slash ("a/b" versus "a / b").
//
// Conservative where it must be: it never expands a LEADING "St" that means "Saint" (see
// foldStreetSuffixes).
//
// LIVE-STORE-CLAIM verified=2026-07-25 measure="shows split across venue spelling variants once the no-collision assumption broke"
// #1498 changed one of #1064's calls. This originally KEPT a trailing city or state, on the reasoning
// that dropping it could merge two same-named venues in different towns, and recorded that the audit had
// seen no collisions. That last part stopped being true: by 2026-07-25 the live store held 34 shows split
// across 71 queue rows on exactly this variance ("Jalopy Theatre" versus "Jalopy Theatre, Red Hook,
// Brooklyn, NY"), so Dan was triaging the same night more than once. `keyName` now reduces a venue to its
// own name for the KEY, and the collision that reasoning feared cannot occur, because every consumer of
// the key also carries the date. Note the reduction is key-only: `strippingEmbeddedAddress` is shared
// with VenueDisplay and still keeps a parent building for the card.
enum VenueNormalization {

    // The single canonical form used for the natural KEY: the venue's own name, then the punctuation fold.
    // Case is preserved here; the key path lowercases downstream in Prospect.canonicalize.
    static func normalizeForKey(_ raw: String) -> String {
        fold(keyName(raw))
    }

    // #1498: for the KEY, a venue reduces to its own name, dropping every trailing clause: a street
    // address, a city, a neighbourhood, or a parent building. Whatever follows the first comma describes
    // WHERE the venue is or what it sits inside, never which venue it is, and a source that sometimes
    // appends it and sometimes does not was splitting one show into several.
    //
    // LIVE-STORE-CLAIM verified=2026-07-25 measure="shows fragmented into extra queue rows by a venue spelling variant"
    // Measured on the live store 2026-07-25: 34 shows had fragmented into 71 queue rows, so Dan was
    // triaging the same night more than once. Every collapse this makes there is a correct one (three
    // spellings of Chatham United Methodist Church, "Jalopy Theatre" with and without Red Hook, Weill
    // Recital Hall with and without Carnegie Hall) and it makes no false merge.
    //
    // #1064 deliberately KEPT the trailing city, reasoning that dropping it could merge two same-named
    // venues in different towns, and recorded that the audit had seen no collisions. That premise is what
    // changed. The risk it named also cannot bite here: every consumer of this key (Prospect and Inquiry
    // natural keys, SameDateVenueMerge) also carries the DATE, and the two show keys carry the group, so
    // two different churches would have to host the same group on the same night to collide.
    //
    // Deliberately NOT done inside `strippingEmbeddedAddress`, which VenueDisplay shares: a card should
    // still read "Weill Recital Hall, Carnegie Hall". This reduction is for identity only.
    static func keyName(_ raw: String) -> String {
        let firstClause = raw.split(separator: ",", omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        // A venue that is nothing but a comma clause keeps its raw form rather than becoming empty.
        return firstClause.isEmpty ? raw : firstClause
    }

    // LIVE-STORE-CLAIM verified=2026-07-17 measure="whether every real street-address clause in the live store's venue strings starts with a digit"
    // A source page can bake the street address directly into the venue string. The heuristic (shared
    // with VenueDisplay, previously private there): split on commas, always keep the first clause (the
    // venue's own name, even if it starts with a digit like "54 Below"), then keep walking clauses only
    // until one starts with a digit, which every real street-address clause in the live store does ("115
    // MacDougal Street", "1140 Park Avenue"...). Everything from that clause onward (the street, and any
    // city/state/zip after it) is dropped. A clause with no leading digit ("Carnegie Hall", "Fabbri
    // Mansion") is a real parent-venue name and is kept.
    static func strippingEmbeddedAddress(_ raw: String) -> String {
        let clauses = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard clauses.count > 1 else { return raw }

        var kept = [clauses[0]]
        for clause in clauses.dropFirst() {
            guard let first = clause.first, !first.isNumber else { break }
            kept.append(clause)
        }
        return kept.joined(separator: ", ")
    }

    // Fold the punctuation and abbreviation variance that does not change which venue is meant.
    static func fold(_ raw: String) -> String {
        var s = normalizeSlashSpacing(raw)
        s = foldStreetSuffixes(s)
        s = dropCommaBeforeStateCode(s)
        s = normalizeCommaSpacing(s)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // "a/b", "a /b", "a/ b", "a  /  b" all become "a / b", matching the curated map key spelling
    // ("stern auditorium / perelman stage").
    private static func normalizeSlashSpacing(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*/\s*"#, with: " / ", options: .regularExpression)
    }

    // Canonical comma spacing: exactly one space after each comma, none before. Applied after the
    // state-code fold so a comma it removed is not re-spaced.
    private static func normalizeCommaSpacing(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*,\s*"#, with: ", ", options: .regularExpression)
    }

    // Expand a trailing street-suffix abbreviation to its full word, per comma-clause, but ONLY when the
    // abbreviation is the LAST token of its clause. "65th St" and "MacDougal St" fold to "...Street", but
    // "St Patrick's Church" (where "St" means Saint and is not the last token) is left untouched. That
    // last-token rule is the guard against the Saint trap: a Saint prefix is always followed by the
    // saint's name, so it is never the last token; a street suffix is. A single-token clause ("St" alone)
    // is too ambiguous to touch and is left as is.
    private static let streetSuffixes: [String: String] = [
        "st": "Street", "ave": "Avenue", "av": "Avenue", "blvd": "Boulevard",
        "rd": "Road", "dr": "Drive", "ln": "Lane", "pl": "Place",
        "sq": "Square", "ct": "Court", "pkwy": "Parkway", "hwy": "Highway", "ter": "Terrace",
    ]

    private static func foldStreetSuffixes(_ s: String) -> String {
        let clauses = s.components(separatedBy: ",")
        let folded = clauses.map { clause -> String in
            var tokens = clause.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2, let last = tokens.last else { return clause }
            let bare = last.hasSuffix(".") ? String(last.dropLast()) : last
            guard let full = streetSuffixes[bare.lowercased()] else { return clause }
            tokens[tokens.count - 1] = full
            return tokens.joined(separator: " ")
        }
        return folded.joined(separator: ",")
    }

    // Remove a comma that sits immediately before a two-letter US state code, so "Chatham, NJ" and
    // "Chatham NJ" agree. Only a standalone two-letter clause that is a real state code is folded, so a
    // venue whose name merely ends in a comma clause is untouched.
    private static let stateCodes: Set<String> = [
        "al", "ak", "az", "ar", "ca", "co", "ct", "de", "fl", "ga", "hi", "id", "il", "in", "ia",
        "ks", "ky", "la", "me", "md", "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj",
        "nm", "ny", "nc", "nd", "oh", "ok", "or", "pa", "ri", "sc", "sd", "tn", "tx", "ut", "vt",
        "va", "wa", "wv", "wi", "wy", "dc",
    ]

    private static func dropCommaBeforeStateCode(_ s: String) -> String {
        let clauses = s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard clauses.count > 1 else { return s }
        var result: [String] = []
        for clause in clauses {
            if clause.count == 2, stateCodes.contains(clause.lowercased()), let prev = result.last,
               !prev.isEmpty {
                result[result.count - 1] = prev + " " + clause
            } else {
                result.append(clause)
            }
        }
        return result.joined(separator: ", ")
    }
}
