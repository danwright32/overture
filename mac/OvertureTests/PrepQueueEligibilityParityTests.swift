import Testing
import Foundation
import SwiftData

// #367 (red-team finding): RootView gates its "Prep kept" button with its OWN SwiftData
// #Predicate-driven @Query, separate from PrepQueueBuilder.needsPrep. A #Predicate macro cannot
// call an arbitrary Swift function, so the two can never literally share one implementation; this
// test instead pins that PrepQueueBuilder.needsPrepPredicate (the shared, named predicate RootView
// now queries with) and PrepQueueBuilder.needsPrep (the plain-Swift function every other call site
// uses) always agree, for every state that matters. If they ever drift, this is the guard that
// catches it, not a silently-disabled "Prep kept" button.
@MainActor
@Suite("Prep queue eligibility: #Predicate and plain-Swift agree")
struct PrepQueueEligibilityParityTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func insert(_ ctx: ModelContext, key: String, status: ReviewStatus, hasDraft: Bool,
                        reprepDraftRequested: Bool = false, reprepContactsRequested: Bool = false) {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hi" }
        p.reprepDraftRequested = reprepDraftRequested
        p.reprepContactsRequested = reprepContactsRequested
        ctx.insert(p)
    }

    @Test func predicateAndFunctionAgreeOnEveryEligibilityCase() throws {
        let ctx = ModelContext(try container())
        insert(ctx, key: "kept-no-draft", status: .queued, hasDraft: false)
        insert(ctx, key: "kept-with-draft-no-flags", status: .queued, hasDraft: true)
        insert(ctx, key: "new-no-draft", status: .new, hasDraft: false)
        insert(ctx, key: "dismissed", status: .dismissed, hasDraft: false)
        insert(ctx, key: "drafted-no-flags", status: .drafted, hasDraft: true)
        insert(ctx, key: "drafted-draft-flag", status: .drafted, hasDraft: true, reprepDraftRequested: true)
        insert(ctx, key: "drafted-contacts-flag", status: .drafted, hasDraft: true, reprepContactsRequested: true)
        insert(ctx, key: "approved-both-flags", status: .approved, hasDraft: true,
               reprepDraftRequested: true, reprepContactsRequested: true)
        insert(ctx, key: "approved-no-flags", status: .approved, hasDraft: true)
        insert(ctx, key: "contacted-with-flags", status: .contacted, hasDraft: true,
               reprepDraftRequested: true, reprepContactsRequested: true)
        insert(ctx, key: "dismissed-with-flags", status: .dismissed, hasDraft: true,
               reprepDraftRequested: true, reprepContactsRequested: true)

        // #901: the conflict gate, in all three of its states. Otherwise the predicate and the function
        // could agree perfectly on every case that predates it and still disagree on every case that
        // matters now.
        let conflicted = Prospect(naturalKey: "kept-but-booked", groupName: "g", discipline: "choral",
                                  venue: "V", performanceDate: "2026-07-01", sourceListingURL: nil, priorRelationship: "none", production: "self",
                                  profile: "strong", coverage: "likely_uncovered", fitScore: 5,
                                  tier: "mid", fitReason: "r", matchedClientName: nil,
                                  possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        conflicted.setScoutConflict(BlockedCalendar.Day(date: "2026-07-01", kind: .dayOff,
                                                        name: "Vacation").key)
        ctx.insert(conflicted)

        let cleared = Prospect(naturalKey: "kept-but-cleared", groupName: "g", discipline: "choral",
                               venue: "V", performanceDate: "2026-07-01", sourceListingURL: nil, priorRelationship: "none", production: "self",
                               profile: "strong", coverage: "likely_uncovered", fitScore: 5,
                               tier: "mid", fitReason: "r", matchedClientName: nil,
                               possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        cleared.setScoutConflict(BlockedCalendar.Day(date: "2026-07-01", kind: .dayOff,
                                                     name: "Vacation").key)
        cleared.clearConflict()          // Dan overruled it, so it is ordinary work again
        ctx.insert(cleared)
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let viaFunction = Set(all.filter(PrepQueueBuilder.needsPrepEligible).map(\.naturalKey))

        let viaPredicate = Set(try ctx.fetch(
            FetchDescriptor<Prospect>(predicate: PrepQueueBuilder.needsPrepPredicate)
        ).map(\.naturalKey))

        #expect(viaPredicate == viaFunction)
        #expect(viaPredicate == Set(["kept-no-draft", "drafted-draft-flag", "drafted-contacts-flag",
                                     "approved-both-flags", "kept-but-cleared"]))
        #expect(!viaPredicate.contains("kept-but-booked"))   // and the conflicted show is in neither
    }
}
