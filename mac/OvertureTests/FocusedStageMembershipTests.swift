import Testing
import Foundation
import SwiftData

// #1140: the focused stage list (tapping the Review pill, say) froze its row membership into a plain
// [String] at tap time and filtered by it forever, so a draft SENT while Dan was inside the Review list
// never left it and the header count never decremented. Membership for a stage pill has to be re-derived
// live from the current prospects, the same way the pill's own count is, so a show that moves out of the
// stage drops out of the focused list too. StageNavigation.focusedKeys is that seam, pulled out of the
// (untestable) SwiftUI view so this can pin it.
@MainActor
@Suite("A focused stage list tracks live membership (#1140)")
struct FocusedStageMembershipTests {
    private let today = ScoutTestClock.stageNavigationAnchor
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: "2026-09-19", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.draftBody = "Hello, I photograph performances."
        ctx.insert(p)
        return p
    }

    // A stage focus re-derives its keys from the live prospects, exactly like naturalKeys, so the focused
    // list shows precisely the stage's current membership.
    @Test func aStageFocusResolvesLiveMembership() throws {
        let ctx = try context()
        show(ctx, "drafted-1", status: .drafted)
        show(ctx, "drafted-2", status: .drafted)
        show(ctx, "already-sent", status: .contacted)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = StageNavigation.focusedKeys(stage: .review, leadKeys: [], in: all, today: today, now: now)
        #expect(Set(keys) == Set(["drafted-1", "drafted-2"]))
    }

    // The regression itself: a draft sent while Dan is inside the Review list (status moves .drafted ->
    // .contacted) is no longer in the focused Review membership, so the card leaves the list.
    @Test func aSentDraftLeavesTheFocusedReviewList() throws {
        let ctx = try context()
        let sending = show(ctx, "mark-morris", status: .drafted)
        show(ctx, "still-drafted", status: .drafted)

        var keys = StageNavigation.focusedKeys(stage: .review, leadKeys: [],
                                               in: try ctx.fetch(FetchDescriptor<Prospect>()),
                                               today: today, now: now)
        #expect(Set(keys) == Set(["mark-morris", "still-drafted"]))

        // Dan approves and sends it: status moves off .drafted.
        sending.status = .contacted
        keys = StageNavigation.focusedKeys(stage: .review, leadKeys: [],
                                           in: try ctx.fetch(FetchDescriptor<Prospect>()),
                                           today: today, now: now)
        #expect(keys == ["still-drafted"])
    }

    // The deep-link leads path (#308) is NOT a stage: it is a specific named set of leads Dan asked to
    // see, so with no stage it returns those keys verbatim, even ones that no longer match any live
    // prospect (the flat focused list renders whichever of them still exist).
    @Test func theLeadsPathKeepsItsFrozenKeySet() throws {
        let ctx = try context()
        show(ctx, "lead-a", status: .new)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let keys = StageNavigation.focusedKeys(stage: nil, leadKeys: ["lead-a", "lead-gone"],
                                               in: all, today: today, now: now)
        #expect(keys == ["lead-a", "lead-gone"])
    }
}
