import Foundation

// #2451: the stored fold keys in this app, and which pass moves each one when its fold changes.
//
// WHY THIS EXISTS AS A VALUE rather than as a paragraph. Four `@Model` columns hold a key computed by
// `OrgKey.of`, `ProducerGate.key` or `VenuePlaces.canonicalKey`, in four different files, and each one
// is written by a different surface. A fold change re-keys all of them at once, and a column that
// nobody re-keys does not fail: its rows simply stop being found, which is #1784's whole finding and
// which is invisible from every file involved.
//
// This list is DELIBERATELY NOT the authority on what is key-bearing. A hand-written registry only ever
// checks what it remembers, and what it remembers is exactly the field somebody already thought about
// (L96). `KeyBearingFieldCoverageTests` derives the real set from the app's own source and fails when
// this list does not cover it, so a new key column fails the suite the day it is added rather than
// being exempted by omission.
enum KeyRealignment {

    // The two behaviours a realignment pass may have, and the difference is the whole of #2451.
    //
    // An ANSWER is a verdict about an organisation or a room. Two rows landing on one key that say the
    // same thing are genuinely one answer written twice, so merging them loses nothing.
    //
    // A PROTECTIVE row is a refusal: Dan saying do not contact this address. Two refusals landing on one
    // key can only ever mean refuse, so there is nothing a merge could resolve and everything it could
    // lose. A refusal ledger one row shorter is indistinguishable from no refusal at all (L42), and it is
    // the exact shape of #2392 leading to #2421: a removal that was not recorded came straight back on
    // the next run. So a protective pass RE-KEYS and never deletes.
    enum TableClass: String, Equatable, Sendable {
        case protective
        case answer
    }

    // One stored key column, named the way the guard can check it against the source.
    struct Field: Equatable, Hashable, Sendable {
        let model: String        // the @Model class holding the column
        let property: String     // the stored property
        let pass: String         // the type whose `run(in:)` moves it
        let tableClass: TableClass
    }

    // Assembled from each pass's own declaration rather than restated here, so a pass and the field it
    // claims to cover cannot drift into two different statements.
    static let coverage: [Field] =
        OrgKeyRealignmentMigration.realigns
        + VenueKeyRealignmentMigration.realigns
        + ProducerOverrideKeyRealignment.realigns
        + RefusedOrgKeyRealignment.realigns

    static func covers(model: String, property: String) -> Bool {
        coverage.contains { $0.model == model && $0.property == property }
    }
}
