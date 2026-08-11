import Foundation

// #1598 (milestone 32 Phase 5.2): WHICH organisation is this, as one key shared by everything that
// reuses an answer across shows (the stored ledger, and the within-run grouping in ProbeBatch).
//
// Deliberately NOT VenueNormalization.normalizeForKey, which every other key in this app uses.
// That rule reduces a string to its FIRST CLAUSE, and it justifies itself (#1498) on the grounds
// that "every consumer of this key also carries the DATE, so two same-named venues in different
// towns cannot collide". An organisation key is the first consumer that does not carry a date.
// Applied to presenter strings it would file every "Christ Church Cathedral" under one key however
// far apart they are, and reduce the duo "Ann Hampton Callaway, Liz Callaway" to one of the two
// women. Both of those strings are in the live store today, and the collapse would be permanent,
// silent, and paid for.
//
// So this keeps every clause that names WHO, and drops only what names WHERE: a street address a
// listing page baked into the name, which `strippingEmbeddedAddress` already isolates by the leading
// digit every real address clause carries, and a parenthetical qualifier.
//
// #1784 SETTLES WHAT THIS KEY IS FOR, because leaving it implicit is what let it drift. This key answers
// "which organisation would Dan email", and that is the same organisation ProducerGate is asking about
// when it decides whether an answer may be reused at all. So the two agree on brackets, through one
// shared strip: a parenthetical says WHERE the organisation is, what it is ALSO CALLED, or who it
// curated one night WITH, and never which organisation it is. Before that, the gate read
// "The Golden Hour Series (curated with Jalopy Theatre, ...)" as one organisation while this key held
// two, and Dan paid for the same contact twice.
//
// It stays STRICTER than the gate in exactly one respect, and that difference is deliberate rather than
// residual: a COMMA clause is kept. It can name a second person ("Ann Hampton Callaway, Liz Callaway")
// or a second town ("Christ Church Cathedral, Oxford"), and the gate may collapse those because its
// verdict is thrown away after the comparison, while this key is written down and decides who receives
// an email. OrgIdentityAgreementTests is where both halves of that are asserted rather than described.
enum OrgKey {
    // The namespace on the STORED key. A ledger row's key sits in a plain string column, so this keeps
    // this key space provably apart from any future one keyed on a venue or a performer, rather than
    // relying on the two never happening to spell a name the same way.
    static let presenterNamespace = "presenter:"

    // The bare identity, for comparing two presenter strings in memory.
    static func of(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // #1784: brackets go FIRST, before the address strip. A bracket whose contents hold a comma
        // ("(curated with Jalopy Theatre, The New Colossus Festival, and others)") is otherwise walked
        // clause by clause by the address rule and survives in pieces, which is the exact shape that put
        // one series in the ledger twice. A name that is nothing BUT a bracket keeps its raw form rather
        // than losing its identity entirely.
        let withoutQualifiers = VenueNormalization.strippingParentheticals(raw)
        let named = withoutQualifiers.isEmpty ? raw : withoutQualifiers
        var key = Prospect.canonicalize(
            VenueNormalization.fold(VenueNormalization.strippingEmbeddedAddress(named)))
        // #2451: a LEADING ARTICLE is dropped, because the other two folds of an organisation's name
        // already drop it and this one did not, which is the disagreement #2451 exists to end.
        // `ProducerGate.key` has stripped it since #1593 ("The Soldiers' and Sailors' Monument" is that
        // monument), `VenuePlaces.key` since #1802, and `GroupNameMatch.isConfident` folds the two
        // spellings together by containment. So "The Green Room 42" and "Green Room 42" were ONE
        // organisation to the gate that decides whether an answer may be reused, and TWO to the ledger
        // that decides who receives the email, which is a second paid lookup and a second row.
        //
        // Applied AFTER canonicalize, which lowercases, so it is one comparison rather than a case
        // list. `key` is already lowercased here, exactly as it is in the two folds above.
        if key.hasPrefix("the ") { key.removeFirst(4) }
        key = key.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    // The identity as it is written to the ledger.
    static func stored(for raw: String?) -> String? {
        guard let key = of(raw) else { return nil }
        return presenterNamespace + key
    }

    // #2451: where a key ALREADY WRITTEN to a row belongs under today's fold.
    //
    // The two realignment passes over tables that keep no raw name (`RefusedContactAddress.scopeId`,
    // and any future claim keyed the same way) cannot re-derive from a presenter string, because the
    // row never held one. So they re-fold the STORED key itself, which is sound because every fold this
    // key is built from is idempotent: a name already reduced to its key reduces to the same key again.
    //
    // Returns nil for anything not in this key space, which is the safe direction and the reason the
    // namespace exists: `scopeId` also holds a prospect's natural key on a show-scoped row, and a pass
    // that re-folded one of those would move a refusal onto a key naming nothing.
    static func realigned(storedKey: String) -> String? {
        guard storedKey.hasPrefix(presenterNamespace) else { return nil }
        guard let key = of(String(storedKey.dropFirst(presenterNamespace.count))) else { return nil }
        return presenterNamespace + key
    }
}
