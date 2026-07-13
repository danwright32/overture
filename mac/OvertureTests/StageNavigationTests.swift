import Testing
import Foundation
import SwiftData
@testable import Overture

// #338: the stage pills (Prep/Review/Send/Follow-ups) become real navigation. This pins down
// which prospects each pill's tap should focus the queue on, using the SAME criteria AgentRoster
// already uses to compute that pill's count/state, so what Dan taps always matches what he sees.
@Suite("Stage navigation (#338)")
struct StageNavigationTests {
    @MainActor
    private func prospect(_ ctx: ModelContext, key: String, status: ReviewStatus,
                          hasDraft: Bool = true, sentAt: Date? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hi" }
        p.sentAt = sentAt
        ctx.insert(p)
        return p
    }

    @MainActor
    private func makeContext() -> ModelContext {
        ModelContext(try! ModelContainer(for: Schema([Prospect.self]),
                                         configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @MainActor
    @Test func prepStageIsQueuedWithNoDraft() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "kept-no-draft", status: .queued, hasDraft: false)
        _ = prospect(ctx, key: "kept-with-draft", status: .queued, hasDraft: true)
        _ = prospect(ctx, key: "drafted", status: .drafted)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = StageNavigation.naturalKeys(forStage: "Prep", in: all)
        #expect(keys == ["kept-no-draft"])
    }

    // #367: a drafted prospect flagged for re-prep also belongs on the Prep pill, even though it
    // already has a draft, so tapping the pill takes Dan to everything actually pending a run.
    @MainActor
    @Test func prepStageAlsoIncludesReprepFlaggedProspects() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "kept-no-draft", status: .queued, hasDraft: false)
        let flaggedDrafted = prospect(ctx, key: "flagged-drafted", status: .drafted, hasDraft: true)
        flaggedDrafted.reprepContactsRequested = true
        let flaggedApproved = prospect(ctx, key: "flagged-approved", status: .approved, hasDraft: true)
        flaggedApproved.reprepDraftRequested = true
        _ = prospect(ctx, key: "unflagged-drafted", status: .drafted, hasDraft: true)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = Set(StageNavigation.naturalKeys(forStage: "Prep", in: all))
        #expect(keys == Set(["kept-no-draft", "flagged-drafted", "flagged-approved"]))
    }

    // #370: the freshly scouted, undecided triage (status .new) gets its own stage, distinct from
    // Prep (which only ever counted kept-undrafted prospects, never .new ones).
    @MainActor
    @Test func scoutStageIsNewProspects() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "new-1", status: .new, hasDraft: false)
        _ = prospect(ctx, key: "new-2", status: .new, hasDraft: false)
        _ = prospect(ctx, key: "kept-no-draft", status: .queued, hasDraft: false)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        // #861: pinned to the fixture's own era, not the wall clock. These shows are dated 2026-07-01,
        // which was "upcoming" the day the test was written and is now three weeks past, so a wall-clock
        // default would correctly filter them out and the test would go red for a reason unrelated to its
        // subject. Inject, do not re-date: re-dating fixtures into the future only rots again (#811).
        let keys = Set(StageNavigation.naturalKeys(forStage: "Scout", in: all, today: "2026-06-01"))
        #expect(keys == Set(["new-1", "new-2"]))
    }

    @MainActor
    @Test func reviewStageIsDrafted() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "drafted-1", status: .drafted)
        _ = prospect(ctx, key: "drafted-2", status: .drafted)
        _ = prospect(ctx, key: "queued", status: .queued, hasDraft: false)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = Set(StageNavigation.naturalKeys(forStage: "Review", in: all))
        #expect(keys == Set(["drafted-1", "drafted-2"]))
    }

    @MainActor
    @Test func sendStageIsApprovedAndNotYetSent() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "waiting-to-send", status: .approved, sentAt: nil)
        _ = prospect(ctx, key: "legacy-sent", status: .approved, sentAt: Date(timeIntervalSince1970: 10))
        _ = prospect(ctx, key: "drafted", status: .drafted)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = StageNavigation.naturalKeys(forStage: "Send", in: all)
        #expect(keys == ["waiting-to-send"])
    }

    @MainActor
    @Test func unknownStageNameReturnsNoKeys() throws {
        let ctx = makeContext()
        _ = prospect(ctx, key: "x", status: .queued, hasDraft: false)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(StageNavigation.naturalKeys(forStage: "Follow-ups", in: all).isEmpty)
        #expect(StageNavigation.naturalKeys(forStage: "Nonsense", in: all).isEmpty)
    }
}

// #861: the Scout pill counted shows that had already happened.
//
// Dan: "How come scout doesn't refresh? There are still performances from June in the scout queue." His
// pill read 102 to triage. Twenty-five of those were June shows, three weeks gone. The real backlog was
// 77.
//
// Two places answered the same question and disagreed. The pill counted `status == .new`, full stop. The
// QUEUE filtered past shows out correctly. So a June show was counted in the pill, was a target of the
// pill's navigation, and was then not rendered when he arrived. StageNavigation's own header rule is
// that what a pill SHOWS is what tapping it takes him TO, and this broke it in the direction that wastes
// his time: it told him he had work that could not be done.
//
// The show is not lost. Archive already shows anything past its window, by derivation, so a show that
// simply went by is already where it belongs. It just has to stop being counted as pending work.
@MainActor
@Suite("A show that already happened is not waiting to be triaged (#861)")
struct PastShowsLeaveTheScoutQueueTests {
    private let today = "2026-07-12"

    private func show(_ key: String, date: String?, runEnd: String? = nil,
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.runEndDate = runEnd
        return p
    }

    @Test func aShowThatAlreadyHappenedIsNotWaitingToBeTriaged() {
        let gone = show("june", date: "2026-06-27")
        let upcoming = show("september", date: "2026-09-19")

        let keys = StageNavigation.naturalKeys(forStage: "Scout", in: [gone, upcoming], today: today)

        #expect(keys == ["september"])
    }

    // A multi-night run that OPENED in the past but is still running tonight is not gone. Judged on its
    // last night, the same rule the ingest guard (#798) and the reconcile both use, so there is one
    // answer to "is this show over" and not three.
    @Test func aRunStillRunningTonightIsStillWaitingOnHim() {
        let running = show("run", date: "2026-07-09", runEnd: "2026-07-20")

        #expect(StageNavigation.naturalKeys(forStage: "Scout", in: [running], today: today) == ["run"])
    }

    // An undated show cannot be judged past, and "date to be confirmed" is a normal state on an org's
    // season page. Dropping it would silently lose a real lead.
    @Test func anUndatedShowIsNeverAssumedToHaveHappened() {
        let undated = show("tbc", date: nil)

        #expect(StageNavigation.naturalKeys(forStage: "Scout", in: [undated], today: today) == ["tbc"])
    }

    // Only the untriaged ones. A show he already kept or dismissed is not waiting on him whatever its
    // date is.
    @Test func aShowHeAlreadyDecidedOnIsNotWaitingEither() {
        let kept = show("kept", date: "2026-09-19", status: .queued)

        #expect(StageNavigation.naturalKeys(forStage: "Scout", in: [kept], today: today).isEmpty)
    }
}
