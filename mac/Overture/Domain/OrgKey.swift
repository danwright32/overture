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
// So this keeps every clause that names WHO, and drops only the one clause that names WHERE: a street
// address a listing page baked into the name, which `strippingEmbeddedAddress` already isolates by
// the leading digit every real address clause carries.
enum OrgKey {
    // The namespace on the STORED key. A ledger row's key sits in a plain string column, so this keeps
    // this key space provably apart from any future one keyed on a venue or a performer, rather than
    // relying on the two never happening to spell a name the same way.
    static let presenterNamespace = "presenter:"

    // The bare identity, for comparing two presenter strings in memory.
    static func of(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = Prospect.canonicalize(
            VenueNormalization.fold(VenueNormalization.strippingEmbeddedAddress(raw)))
        return key.isEmpty ? nil : key
    }

    // The identity as it is written to the ledger.
    static func stored(for raw: String?) -> String? {
        guard let key = of(raw) else { return nil }
        return presenterNamespace + key
    }
}
