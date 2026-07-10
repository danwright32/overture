import Testing
import Foundation
import SwiftData
@testable import Overture

// Phase 2.5 (#393): the one-shot, idempotent launch pass that recovers a salutation-free body from
// legacy drafts authored with an inline greeting, so the app can render the greeting per recipient at
// send. Conservative: it strips only when safe and flags the rest for Dan, never corrupting copy.
@MainActor
@Suite("Draft salutation migration")
struct DraftSalutationMigrationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func prospect(_ key: String, draft: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.draftBody = draft
        return p
    }

    @Test func stripsALegacyInlineGreetingFromTheStoredBody() throws {
        let ctx = try context()
        let p = prospect("k1", draft: "Hi Emma, I photograph performing arts in New York.")
        ctx.insert(p)

        let count = DraftSalutationMigration.run(in: ctx)

        #expect(count == 1)
        #expect(p.draftBody == "I photograph performing arts in New York.")
        #expect(p.draftNeedsSalutationReview == false)
    }

    @Test func leavesAnAlreadySalutationFreeDraftUntouched() throws {
        let ctx = try context()
        let body = "I photograph performing arts in New York."
        let p = prospect("k1", draft: body)
        ctx.insert(p)

        let count = DraftSalutationMigration.run(in: ctx)

        #expect(count == 0)
        #expect(p.draftBody == body)
    }

    @Test func flagsAmbiguousGreetingsForReviewWithoutChangingTheBody() throws {
        let ctx = try context()
        let body = "Hi 2026 season, here is what we offer."
        let p = prospect("k1", draft: body)
        ctx.insert(p)

        _ = DraftSalutationMigration.run(in: ctx)

        #expect(p.draftBody == body)
        #expect(p.draftNeedsSalutationReview == true)
    }

    @Test func isIdempotentAcrossRuns() throws {
        let ctx = try context()
        let p = prospect("k1", draft: "Hi Emma, I photograph performing arts.")
        ctx.insert(p)

        _ = DraftSalutationMigration.run(in: ctx)
        let secondRun = DraftSalutationMigration.run(in: ctx)

        #expect(secondRun == 0)
        #expect(p.draftBody == "I photograph performing arts.")
    }

    // #407: the flag is re-derived from the CURRENT body every run, not a one-way latch, so it
    // clears once Dan (or a fresh Prep re-run) actually fixes the draft.
    @Test func clearsThePreviouslySetFlagOnceTheBodyNoLongerNeedsReview() throws {
        let ctx = try context()
        let p = prospect("k1", draft: "Hi 2026 season, here is what we offer.")
        ctx.insert(p)
        _ = DraftSalutationMigration.run(in: ctx)
        #expect(p.draftNeedsSalutationReview == true)

        p.draftBody = "Here is what we offer this season."   // Dan rewrote it by hand
        _ = DraftSalutationMigration.run(in: ctx)

        #expect(p.draftNeedsSalutationReview == false)
    }
}
