import Testing
import Foundation

// #2499: what `KeyRealignment` CLAIMS about each stored fold key, and the difference between the two
// claims it can make.
//
// `coverage` means a pass moves this column when its fold changes. `watchedWithoutAPass` means nothing
// moves it and here is why. Those are different facts, and one status field holding both would let the
// second hide inside the first (L11, L53), so they are separate lists and separate questions.
@Suite("What KeyRealignment claims about each stored fold key (#2499)")
struct KeyCoverageDeclarationTests {
    // The fold that builds `Prospect.naturalKey` had a SHIPPED pass and no entry in this list, so it
    // was covered in fact and not by the guard, which is the same thing the day somebody changes the
    // fold and reads the list.
    @Test func theNaturalKeyFoldIsDeclaredByThePassThatMovesIt() {
        #expect(NaturalKeyVenueMigration.realigns.contains(
            KeyRealignment.Field(model: "Prospect", property: "naturalKey",
                                 pass: "NaturalKeyVenueMigration", tableClass: .answer)))
        // Asked of `coverage` DIRECTLY rather than through a helper. A helper for this would be named
        // by the tests and by nothing else in the app, which `TestOnlyReachableDomainCodeTests` refuses
        // and rightly: a reader only the suite can reach is one the app never uses (#3154).
        #expect(KeyRealignment.coverage.contains {
            $0.model == "Prospect" && $0.property == "naturalKey"
        })
    }

    // Assembled from the passes rather than restated, which is what stops a pass and the field it
    // claims to cover drifting into two different statements.
    @Test func theCoverageListIsBuiltFromEachPassesOwnDeclaration() {
        for field in NaturalKeyVenueMigration.realigns {
            #expect(KeyRealignment.coverage.contains(field))
        }
    }

    // The town tables are WATCHED, not covered, and asking the stronger question must say so. Without
    // this, the two claims collapse into one and a field with no pass reads as protected (L11).
    @Test func theTownTablesAreWatchedRatherThanCovered() {
        for model in ["ExcludedTown", "AllowedSeedTown"] {
            #expect(KeyRealignment.covers(model: model, property: "town"),
                    "\(model).town is accounted for")
            #expect(!KeyRealignment.coverage.contains { $0.model == model && $0.property == "town" },
                    "\(model).town has NO pass, and saying it does would be a claim nothing measured")
        }
    }

    // And the two lists are genuinely disjoint, so a field cannot be both, which is what would make the
    // distinction above meaningless.
    @Test func nothingIsBothCoveredAndMerelyWatched() {
        let covered = Set(KeyRealignment.coverage.map { "\($0.model).\($0.property)" })
        let watched = Set(KeyRealignment.watchedWithoutAPass.map { "\($0.model).\($0.property)" })
        #expect(covered.intersection(watched).isEmpty)
        #expect(!covered.isEmpty && !watched.isEmpty, "both lists must hold something or this measured nothing")
    }
}
