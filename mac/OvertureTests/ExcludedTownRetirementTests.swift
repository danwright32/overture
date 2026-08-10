import Testing
import Foundation
import SwiftData

// #1238 follow-up: when Dan blocks a town ("Never show me shows in <town>"), the shows there must
// actually leave his queue, now AND for every future scout, not merely stop reaching the prep queue.
// Before this, the town refusal was a view-time filter that the stage views (the only navigation since
// #1134) never applied, so a blocked-town show stayed on screen and future scouts kept surfacing it.
//
// The fix mirrors WentByRetirement (#864): a show in an excluded town (Dan's refusal OR the built-in
// seed) is dismissed with a reason of its OWN ("Too far"), which must never read as a judgement Dan
// made about the org, because Overture watches out-of-town orgs for their occasional NYC dates (#970),
// so a blocked-town cut must never teach the next scout to pass on the org everywhere.
@MainActor
@Suite("A show in a blocked town is dismissed, now and for future scouts (#1238)")
struct ExcludedTownRetirementTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, ExcludedTown.self, AllowedSeedTown.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, location: String?,
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "opera", venue: "A venue",
                         performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.location = location
        ctx.insert(p)
        return p
    }

    private func block(_ ctx: ModelContext, _ town: String) {
        _ = ExcludedTownEditing.exclude(town: town, into: ctx)
    }

    // MARK: - What gets retired

    @Test func aShowInATownDanBlockedIsRetired() throws {
        let ctx = try context()
        block(ctx, "Chautauqua")
        let blocked = show(ctx, "chautauqua-opera", location: "Chautauqua, NY")

        let retired = ExcludedTownRetirement.run(in: ctx)

        #expect(retired == 1)
        #expect(blocked.status == .dismissed)
        #expect(blocked.showOutcome == .tooFar)
    }

    // A built-in seed town (Buffalo et al.) is excluded the moment the pass runs, with no refusal needed:
    // the gate reads seed and refusals as one set (#991), so retirement must too, or Chautauqua would
    // leave the queue while Buffalo, which Dan never has to refuse, would not.
    @Test func aShowInASeedTownIsRetiredWithoutARefusal() throws {
        let ctx = try context()
        let buffalo = show(ctx, "buffalo-opera", location: "Buffalo, NY")

        #expect(ExcludedTownRetirement.run(in: ctx) == 1)
        #expect(buffalo.showOutcome == .tooFar)
    }

    @Test func anInRangeShowIsLeftAlone() throws {
        let ctx = try context()
        block(ctx, "Chautauqua")
        let manhattan = show(ctx, "manhattan-opera", location: "New York, NY")

        #expect(ExcludedTownRetirement.run(in: ctx) == 0)
        #expect(manhattan.status == .new)
    }

    // #1221: a seed town Dan has explicitly UN-SKIPPED is back in range and must not be retired.
    @Test func anUnskippedSeedTownIsLeftAlone() throws {
        let ctx = try context()
        _ = ExcludedTownEditing.allowSeedTown("buffalo", into: ctx)
        let buffalo = show(ctx, "buffalo-opera", location: "Buffalo, NY")

        #expect(ExcludedTownRetirement.run(in: ctx) == 0)
        #expect(buffalo.status == .new)
    }

    // Dan's own spec: skip shows he already committed to (contacted or approved), so blocking a town
    // never nukes live outreach. A show he only kept/drafted but never sent is still his to lose here.
    @Test func aShowDanAlreadyContactedOrApprovedIsNeverTouched() throws {
        let ctx = try context()
        block(ctx, "Chautauqua")
        let committed: [Prospect] = [
            show(ctx, "approved", location: "Chautauqua, NY", status: .approved),
            show(ctx, "contacted", location: "Chautauqua, NY", status: .contacted),
        ]

        #expect(ExcludedTownRetirement.run(in: ctx) == 0)
        for p in committed { #expect(p.status != .dismissed, "\(p.naturalKey) had live outreach") }
    }

    // Assume it runs twice: it runs on every launch and after every scout, so a second pass must find
    // nothing left and must not disturb a genuine cut Dan made himself.
    @Test func runningItTwiceChangesNothingTheSecondTime() throws {
        let ctx = try context()
        block(ctx, "Chautauqua")
        let blocked = show(ctx, "chautauqua-opera", location: "Chautauqua, NY")
        let danCut = show(ctx, "dan-cut", location: "New York, NY", status: .dismissed)
        danCut.showOutcome = .notAFit

        #expect(ExcludedTownRetirement.run(in: ctx) == 1)
        #expect(ExcludedTownRetirement.run(in: ctx) == 0)
        #expect(blocked.showOutcome == .tooFar)
        #expect(danCut.showOutcome == .notAFit)
    }

    // MARK: - It must never read as a decision Dan made about the org

    // The guarantee that matters most. Overture watches out-of-town orgs for their occasional NYC dates
    // (#970 point 7): the same org that plays Chautauqua may also play Carnegie. If blocking the town
    // taught LocalHistory that Dan "declined" the org, it would penalise that org's legitimate NYC date.
    @Test func aBlockedTownCutTeachesTheNextScoutNothing() throws {
        let ctx = try context()
        block(ctx, "Chautauqua")
        show(ctx, "chautauqua-opera", location: "Chautauqua, NY")

        ExcludedTownRetirement.run(in: ctx)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(LocalHistory.records(from: all).isEmpty,
                "blocking a town must never become a standing signal about the org")
    }

    // MARK: - Undo brings back exactly what the block removed

    @Test func undoingATownBlockBringsItsShowsBack() throws {
        let ctx = try context()
        block(ctx, "Chautauqua")
        let blocked = show(ctx, "chautauqua-opera", location: "Chautauqua, NY")
        ExcludedTownRetirement.run(in: ctx)
        #expect(blocked.status == .dismissed)

        ExcludedTownRetirement.restore(town: "chautauqua", in: ctx)

        #expect(blocked.status == .new)
        #expect(blocked.showOutcome == nil)
    }

    // Undo restores only THIS town's automatic cuts: never a cut Dan made himself, never another town.
    @Test func undoingATownLeavesOtherCutsAlone() throws {
        let ctx = try context()
        let danCut = show(ctx, "dan-cut", location: "Chautauqua, NY", status: .dismissed)
        danCut.showOutcome = .notAFit
        let buffalo = show(ctx, "buffalo", location: "Buffalo, NY")
        ExcludedTownRetirement.run(in: ctx)   // buffalo (seed) is retired with tooFar
        #expect(buffalo.showOutcome == .tooFar)

        ExcludedTownRetirement.restore(town: "chautauqua", in: ctx)

        #expect(danCut.status == .dismissed, "a cut Dan made himself must survive Undo")
        #expect(danCut.showOutcome == .notAFit)
        #expect(buffalo.status == .dismissed, "undoing Chautauqua must not touch Buffalo")
    }
}
