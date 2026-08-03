import Testing
import Foundation
import SwiftData

// Phase 2.5 (#393) recovered a salutation-free body from legacy drafts by STRIPPING the greeting out of
// the stored text at every launch.
//
// #2010 ended that. Dan's rule (2026-08-03): "I want whatever is in the text box that I see to be what's
// sent. There should never be any hidden addition that I cannot see in the app." Rewriting his stored
// words at launch is the same overreach from the other side, and it made the outcome of typing a greeting
// depend on whether he had restarted the app.
//
// What is left is the one thing that still has to happen: clearing the review flag those runs latched onto
// rows, which would otherwise keep them unsendable forever. The body itself is now never touched, and
// `DraftOpeningNotice` says plainly when a body greets as well as the opening above it. The rest of the
// rule lives in OvertureNeverRewritesDansTextTests.
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

    // The rule. A legacy inline greeting is Dan's text now, and it stays exactly as it is.
    @Test func alegacyInlineGreetingIsLeftExactlyWhereItIs() throws {
        let ctx = try context()
        let p = prospect("k1", draft: "Hi Emma, I photograph performing arts in New York.")
        ctx.insert(p)

        _ = DraftSalutationMigration.run(in: ctx)

        #expect(p.draftBody == "Hi Emma, I photograph performing arts in New York.")
    }

    // The one job it still has. A row latched with the flag by an earlier build is unsendable until
    // something clears it, and nothing else would.
    @Test func alatchedReviewFlagIsClearedSoTheRowCanSendAgain() throws {
        let ctx = try context()
        let p = prospect("k1", draft: "I photograph performing arts in New York.")
        p.draftNeedsSalutationReview = true
        ctx.insert(p)

        let cleared = DraftSalutationMigration.run(in: ctx)

        #expect(cleared == 1)
        #expect(p.draftNeedsSalutationReview == false)
    }

    // Idempotent, and it stays idempotent for the ordinary case: with nothing latched it touches nothing
    // and reports nothing, so it never re-announces on every launch.
    @Test func itdoesNothingOnAStoreWithNothingLatched() throws {
        let ctx = try context()
        let p = prospect("k1", draft: "Hi Emma, I photograph performing arts.")
        ctx.insert(p)

        #expect(DraftSalutationMigration.run(in: ctx) == 0)
        #expect(DraftSalutationMigration.run(in: ctx) == 0)
        #expect(p.draftBody == "Hi Emma, I photograph performing arts.")
    }
}
