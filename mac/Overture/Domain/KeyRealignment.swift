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
        // #2499: a fold that was covered in FACT by a shipped pass and not by this list, which is the
        // same as uncovered the day somebody changes it and reads the list.
        //
        // `DuplicateContactMerge` is the OTHER one #2499 names, and it is deliberately not here. It
        // re-keys `Recipient.id`, so it belongs in spirit, and it fits NEITHER class: it deletes the
        // losing row, so it is not protective, and it reports a bare count rather than the
        // rekeyed/duplicatesDeleted/conflictsDeferred summary every answer pass here carries, so
        // `RefusalRealignmentNeverDeletesTests` refuses it as answer-shaped too. Both refusals are
        // correct. Declaring it means reshaping shipping code to fit a taxonomy, or adding a third
        // class, and that is a decision rather than a tidy-up: recorded on #2499 rather than forced.
        + NaturalKeyVenueMigration.realigns

    // #2499: a stored fold key with NO realignment pass, and a stated reason there is none.
    //
    // Its own list rather than a seventh entry above, because "a pass moves this" and "nothing moves
    // this and here is why" are different facts and one status field for both would let the second hide
    // inside the first (L11, L53). A field here is NOT covered; it is WATCHED.
    //
    // `ExcludedTown.town` and `AllowedSeedTown.town` are built by `ExcludedTownEditing.normalize`, which
    // is trim plus lowercase. MEASURED on the live store 2026-09-04 through `LiveStoreClone`: 4 excluded
    // towns, 0 allowed, and ZERO out of step with that fold. So a pass would move nothing today, and
    // writing one that rewrites Dan's refusals to do nothing is a destructive change with no cause
    // (L5). The risk it would guard against fails OPEN (a stranded row un-blocks a town he refused, so
    // the show comes back rather than vanishing), which is why #2499 is p3.
    //
    // What stands in for the pass is `TownKeyAlignmentLiveStoreTests`, which re-measures that zero on
    // every run against his real store and names any row that drifts. The day one does, this becomes a
    // pass; until then it is a number somebody is watching rather than a paragraph nobody re-checks
    // (L316, L336).
    static let watchedWithoutAPass: [Field] = [
        Field(model: "ExcludedTown", property: "town",
              pass: "TownKeyAlignmentLiveStoreTests", tableClass: .protective),
        Field(model: "AllowedSeedTown", property: "town",
              pass: "TownKeyAlignmentLiveStoreTests", tableClass: .protective),
    ]

    // #2499: accounted for, by a pass OR by a standing watch. A caller needing the STRONGER claim asks
    // `coverage` directly, which is what the tests do: a helper for it here would be named by the suite
    // and by nothing else in the app, and `TestOnlyReachableDomainCodeTests` refuses that (#3154).
    static func covers(model: String, property: String) -> Bool {
        (coverage + watchedWithoutAPass).contains { $0.model == model && $0.property == property }
    }
}
