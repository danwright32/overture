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

    // #4136: the rule now reads the calendar, so the day it is judged on is pinned, ahead of every
    // fixture date below except the one row that exists to have passed.
    private let today = "2026-06-01"

    private func insert(_ ctx: ModelContext, key: String, status: ReviewStatus, hasDraft: Bool,
                        reprepDraftRequested: Bool = false, reprepContactsRequested: Bool = false,
                        date: String = "2026-07-01") {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: date, sourceListingURL: nil,
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
        // #4136: kept and undrafted, but its night is behind `today`.
        insert(ctx, key: "kept-no-draft-already-performed", status: .queued, hasDraft: false,
               date: "2026-05-20")

        // #3369: the conflict gate is gone from BOTH halves, and these two rows are what proves it left
        // them in step. The predicate is a #Predicate mirror of the function and cannot share code with
        // it, so removing the gate from one and not the other would have the "Prep kept" button's @Query
        // disagree with every other caller, silently. Kept rather than deleted for exactly that reason:
        // the rows still matter, only the expected answer changed.
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
        let viaFunction = Set(all.filter { PrepQueueBuilder.needsPrepEligible($0, today: today) }
            .map(\.naturalKey))

        let viaPredicate = Set(try ctx.fetch(
            FetchDescriptor<Prospect>(predicate: PrepQueueBuilder.needsPrepPredicate)
        ).map(\.naturalKey))

        // #4136: the predicate mirrors the STATUS half only, since a @Query cannot follow the clock, so it
        // is a superset larger by exactly the shows whose last night has passed. RootView applies the whole
        // rule over what it fetches (`PrepQueueBuilder.eligible`), and that is equal to the function.
        #expect(viaPredicate.subtracting(viaFunction) == ["kept-no-draft-already-performed"])
        #expect(viaFunction.isSubset(of: viaPredicate))
        let fetched = try ctx.fetch(FetchDescriptor<Prospect>(predicate: PrepQueueBuilder.needsPrepPredicate))
        #expect(Set(PrepQueueBuilder.eligible(fetched, today: today).map(\.naturalKey)) == viaFunction)
        // #4170: `contacted-with-flags` joined this list, and it is the row that would catch the new
        // status being allowed in one half and refused in the other. A sent show is prep eligible ONLY
        // with a flag on it, which nothing but a deliberate press sets; `dismissed-with-flags` is the
        // other half of that rule and is still absent.
        #expect(viaFunction == Set(["kept-no-draft", "drafted-draft-flag", "drafted-contacts-flag",
                                    "approved-both-flags", "contacted-with-flags",
                                    "kept-but-cleared", "kept-but-booked"]))
        #expect(!viaPredicate.contains("dismissed-with-flags"))
        #expect(!viaFunction.contains("dismissed-with-flags"))
        // #3369: the conflicted show is in BOTH now. It is the row that would catch the gate being
        // removed from one half and left in the other.
        #expect(viaPredicate.contains("kept-but-booked"))
        #expect(viaFunction.contains("kept-but-booked"))
    }
}
