import Foundation

// #2422: is this incoming contact the SAME PERSON as one already on this show, found through a second
// handle, and if so which of the two ways in is the better one?
//
// Dan, on the live build 2026-08-10, looking at a prepped card: "and I've got two of the same person."
// He had "Devin Marlowe, No email yet" and "Devin Marlowe, devin@devinmarlowe.example" as two rows
// on one show, with the draft composing a greeting for each. Six more pairs were sitting in the store,
// including two where the LATER find was strictly worse: a performer with a booking page on her own site
// gained an Instagram beside it, and the two now read as two people.
//
// The importer matched by id, which is the email or `form:<url>`, so one person reached two ways gets two
// ids by construction; and by provenance, which is switched off on any show carrying more than one
// contact of that provenance (#408), which is every multi performer show this app exists to pitch. The
// name was on both rows, identically, and nothing looked at it.
//
// L15 says a display name is not a key, and this does not make it one: nothing is stored against a name,
// no row is addressed by it, and a name is used ONLY to ask whether two rows ON ONE SHOW are the same
// person, where it is the only signal the payload carries. Every use below refuses when the answer is
// ambiguous rather than guessing.
enum ContactIdentity {

    // A person's name, folded for comparison. Nil when there is nothing to compare, which is the answer
    // that makes every caller refuse: a contact with no name must never match another with no name.
    //
    // Accents fold first, for the same reason GroupNameMatch folds them (#774/#755): the strip below
    // removes everything outside a-z0-9, so "Sinéad" would otherwise shred into tokens that cannot match
    // the same name typed without the accent. Case, punctuation and repeated spaces are canonicalisation,
    // none of which can lose an identity.
    //
    // Deliberately NOT GroupNameMatch.normalize: that one strips a trailing subtitle after a dash or
    // colon, which is right for "Presenter - Program" and wrong for a person ("Miguel Amell - Baritone"
    // and "Miguel Amell" should match, but so should a hyphenated surname stay whole, and the org rule
    // would take "Rodriguez" off "Ana Maria Rodriguez - Soprano" only when the prefix is two words).
    static func personKey(_ name: String?) -> String? {
        guard let name else { return nil }
        var s = name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        s = s.lowercased()
        s = s.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        // A single character is not a name anybody can be identified by, and two people initialled the
        // same way would merge into one row.
        guard s.count > 1 else { return nil }
        return s
    }

    // Two names are the same person only when both fold to something and the two are equal.
    static func isSamePerson(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let l = personKey(lhs), let r = personKey(rhs) else { return false }
        return l == r
    }

    // Which form URL survives a merge. The rule Dan already has for whether a form is worth showing him
    // at all (#1626: an Instagram is a dead end he will not use) decides which of two is better, so the
    // card and the merge cannot disagree about what a usable route is.
    //
    // Never replaces a usable form with a social one, which is the case the store actually held: Cydney
    // McQuillan-Grace's own booking page and Maggie Stephens' own contact page were each found first and
    // then joined by an Instagram. Where neither is better, the existing one stays, so a re-run cannot
    // churn a row between two equally good links.
    static func preferredFormURL(existing: String?, incoming: String?) -> String? {
        let existingUsable = existing.map { !Reachability.isSocialOnly($0) } ?? false
        guard let incoming, !incoming.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return incoming }
        if !existingUsable, !Reachability.isSocialOnly(incoming) { return incoming }
        return existing
    }
}
