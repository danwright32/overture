import Testing
import Foundation
import SwiftData
@testable import Overture

// #991: the missing half of the geography rule. The exclude list starts permissive and ONLY Dan's
// refusal narrows it, exactly the way the watchlist grows (#768). Until now a twentieth town could
// only be added by editing Swift; these tests pin the in-app refusal that adds it to a stored set.
@MainActor
@Suite("Excluding a town from inside the app (#991)")
struct ExcludedTownEditingTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([ExcludedTown.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @Test func excludingATownStoresItNormalized() throws {
        let ctx = try context()
        #expect(ExcludedTownEditing.exclude(town: "Poughkeepsie", into: ctx) == .added)
        #expect(ExcludedTownEditing.names(in: ctx) == ["poughkeepsie"])
    }

    // Idempotent (Dan's spec): the same town, any casing or padding, is a no-op, never a duplicate row.
    @Test func excludingTheSameTownTwiceIsANoOp() throws {
        let ctx = try context()
        #expect(ExcludedTownEditing.exclude(town: "Poughkeepsie", into: ctx) == .added)
        #expect(ExcludedTownEditing.exclude(town: "  poughkeepsie ", into: ctx) == .alreadyExcluded)
        #expect(ExcludedTownEditing.names(in: ctx).count == 1)
    }

    // A town already in the seed list is already excluded: adding it stores nothing new, so the stored
    // set never duplicates what the seed already covers.
    @Test func aSeedTownIsAlreadyExcluded() throws {
        let ctx = try context()
        #expect(ExcludedTownEditing.exclude(town: "Buffalo", into: ctx) == .alreadyExcluded)
        #expect(ExcludedTownEditing.names(in: ctx).isEmpty)
    }

    // The edge case: nothing placeable to exclude is not an error and not a row, it is simply nothing.
    @Test func nothingToExcludeWhenTheTownIsEmpty() throws {
        let ctx = try context()
        #expect(ExcludedTownEditing.exclude(town: "   ", into: ctx) == .noTown)
        #expect(ExcludedTownEditing.names(in: ctx).isEmpty)
    }

    // Reversible (the #845 principle): the Undo path removes exactly the row it added.
    @Test func aTownCanBeRemovedAgain() throws {
        let ctx = try context()
        _ = ExcludedTownEditing.exclude(town: "Poughkeepsie", into: ctx)
        ExcludedTownEditing.remove(town: "Poughkeepsie", in: ctx)
        #expect(ExcludedTownEditing.names(in: ctx).isEmpty)
    }
}

// The row action itself (a guard and its wiring are two claims, #887): the button on the row must take
// the town off the ITEM's location and persist it, not just call a helper with a hand-fed string.
@MainActor
@Suite("The 'never show me this town' row action (#991)")
struct ExcludeTownActionTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([ExcludedTown.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func item(location: String?) -> QueueItem {
        QueueItem(id: "k", groupName: "A Show", discipline: "theater", venue: "Hall",
                  performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil, location: location,
                  priorRelationship: "none", production: "self", profile: "strong", coverage: "unknown",
                  fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                  possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    @Test func excludingFromARowStoresItsTown() throws {
        let ctx = try context()
        ProspectMutations.excludeTown(item(location: "Poughkeepsie, NY"), context: ctx, feedback: ActionFeedback())
        #expect(ExcludedTownEditing.names(in: ctx) == ["poughkeepsie"])
    }

    // The edge case: a row with no placeable, in-region, non-borough town offers nothing and stores
    // nothing, so a stray tap can never write a garbage row.
    @Test func excludingARowWithNoTownDoesNothing() throws {
        let ctx = try context()
        ProspectMutations.excludeTown(item(location: "New York, NY"), context: ctx, feedback: ActionFeedback())
        ProspectMutations.excludeTown(item(location: nil), context: ctx, feedback: ActionFeedback())
        #expect(ExcludedTownEditing.names(in: ctx).isEmpty)
    }
}
