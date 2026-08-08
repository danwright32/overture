import Testing
import Foundation
import SwiftData

// #1802: the backfill that ships with the fold change. Dan's own answer about where a room is must survive
// the app changing its mind about how a room's name folds into a key.
@Suite("Dan's room answers move with the identity (#1802)")
struct VenueKeyRealignmentTests {

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([VenuePlaceAnswer.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func answer(_ key: String, name: String, location: String,
                        at: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> VenuePlaceAnswer {
        VenuePlaceAnswer(venueKey: key, venueName: name, location: location, answeredAt: at)
    }

    // The row this exists for: filed under the spelling that carried a leading article, which nothing
    // computes any more.
    @MainActor
    @Test func anAnswerUnderTheOldSpellingIsMovedOntoTodaysKey() throws {
        let ctx = try context()
        let row = answer("the green room 42", name: "The Green Room 42", location: "New York, NY")
        ctx.insert(row)

        let summary = VenueKeyRealignmentMigration.run(in: ctx)
        #expect(summary.rekeyed == 1)
        #expect(row.venueKey == VenuePlaces.canonicalKey(for: "The Green Room 42"))
        #expect(row.venueKey == VenuePlaces.canonicalKey(for: "Green Room 42"),
                "and both spellings now find it")
    }

    // Idempotent by construction: the condition is "this row is not on the key its own name computes",
    // and the pass writes that key.
    @MainActor
    @Test func aSecondRunChangesNothing() throws {
        let ctx = try context()
        ctx.insert(answer("the green room 42", name: "The Green Room 42", location: "New York, NY"))
        _ = VenueKeyRealignmentMigration.run(in: ctx)
        #expect(VenueKeyRealignmentMigration.run(in: ctx) == VenueKeyRealignmentMigration.Summary())
    }

    // Two rows landing on one key that AGREE: the newer keeps the key, the redundant one goes.
    @MainActor
    @Test func twoAnswersThatAgreeAreMergedOntoTheNewer() throws {
        let ctx = try context()
        let older = answer("the green room 42", name: "The Green Room 42", location: "New York, NY",
                           at: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = answer("green room 42", name: "Green Room 42", location: "new york, ny ",
                           at: Date(timeIntervalSince1970: 1_780_000_000))
        ctx.insert(older); ctx.insert(newer)

        let summary = VenueKeyRealignmentMigration.run(in: ctx)
        #expect(summary.duplicatesDeleted == 1)
        let left = try ctx.fetch(FetchDescriptor<VenuePlaceAnswer>())
        #expect(left.count == 1)
        #expect(left.first?.answeredAt == newer.answeredAt)
    }

    // And two that DISAGREE are a question, not a duplicate. Nothing is deleted and nothing is re-keyed:
    // a launch pass may not answer it by picking a side.
    @MainActor
    @Test func twoAnswersThatDisagreeAreLeftAlone() throws {
        let ctx = try context()
        ctx.insert(answer("the green room 42", name: "The Green Room 42", location: "New York, NY"))
        ctx.insert(answer("green room 42", name: "Green Room 42", location: "Brooklyn, NY"))

        let summary = VenueKeyRealignmentMigration.run(in: ctx)
        #expect(summary.conflictsDeferred == 1)
        #expect(summary.rekeyed == 0)
        #expect(summary.duplicatesDeleted == 0)
        #expect(try ctx.fetch(FetchDescriptor<VenuePlaceAnswer>()).count == 2)
    }

    // A name that folds to nothing keeps the key it has. A failed fold must not cost Dan an answer.
    @MainActor
    @Test func aNameThatFoldsToNothingKeepsItsKey() throws {
        let ctx = try context()
        let row = answer("some-old-key", name: "   ", location: "New York, NY")
        ctx.insert(row)

        _ = VenueKeyRealignmentMigration.run(in: ctx)
        #expect(row.venueKey == "some-old-key")
    }
}
