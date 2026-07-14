import Testing
import Foundation
import SwiftData
@testable import Overture

// #901: "I can shoot this anyway", and the way back from it.
//
// The way back matters as much as the action. Clearing a conflict is what unlocks drafting and sending a
// show on a night Dan is booked or away, so a mis-click is exactly the kind of mistake he must be able to
// take back in place, the way #845 made stopping a source reversible from the banner it happened in.
@MainActor
@Suite("Clearing a date conflict (#901)")
struct ClearConflictMutationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func conflicted(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-11-14",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.setScoutConflict(BlockedCalendar.Day(date: "2026-11-14", kind: .dayOff, name: "Vacation").key)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func clearingItUnblocksTheShow() throws {
        let ctx = try context()
        let p = conflicted(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.clearConflict(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        #expect(p.hasUnclearedConflict == false)
        #expect(p.conflictNote == "You blocked Nov 14 (Vacation).")   // the clash is still TRUE, and still said
    }

    // The banner names what he just did and offers the way back, in the same sentence.
    @Test func theBannerSaysWhatHappenedAndOffersUndo() throws {
        let ctx = try context()
        let p = conflicted(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.clearConflict(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        #expect(feedback.message == "Vienna Philharmonic can be drafted despite the clash")
        #expect(feedback.action?.label == "Undo")
    }

    @Test func undoPutsTheFlagBack() throws {
        let ctx = try context()
        let p = conflicted(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.clearConflict(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)
        feedback.action?.perform()

        #expect(p.hasUnclearedConflict)                                // blocked again
        #expect(PrepQueueBuilder.needsPrepEligible(p) == false)
    }

    // A show with no conflict has nothing to clear, and asking must not invent a clearance that would
    // silently pre-approve the NEXT conflict to land on it.
    @Test func clearingAShowWithNoConflictChangesNothing() throws {
        let ctx = try context()
        let p = conflicted(ctx)
        p.setScoutConflict(nil)                                       // the vacation was cancelled
        let feedback = ActionFeedback()

        ProspectMutations.clearConflict(QueueItem(p), prospects: [p], context: ctx, feedback: feedback)

        #expect(p.conflictClearedKey == nil)
        #expect(feedback.message == nil)                              // and it says nothing happened
    }
}
