import Testing
import Foundation
import SwiftData

// #1940: a show waiting on a re-prep leaves the Review count until the run that carries the request ends.
//
// Dan, 2026-08-01: Review holds drafts worth reading NOW, and a draft that is about to be rewritten is not
// one of those. #367 put a re-prepped show in Prep while leaving it in Review, and #1800 recorded that
// overlap as deliberate (the old draft is still readable until the run replaces it), so this is a
// deliberate reversal of that decision rather than a drift away from it.
//
// The half that has to hold with it is the return (L45): the filters must cover the whole state space
// between them, so a show that leaves Review must land in Prep or Prep blocked, and must come back to
// Review once the run has ended, INCLUDING a run that finished without producing anything.
@MainActor
@Suite("A show waiting on a re-prep leaves Review (#1940)")
struct ReprepLeavesReviewTests {
    private func makeContext() -> ModelContext {
        ModelContext(try! ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                         configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, status: ReviewStatus,
                      hasDraft: Bool = true) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "theatre", venue: "Under St Marks",
                         performanceDate: "2099-08-14", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        if hasDraft { p.draftBody = "Hi" }
        ctx.insert(p)
        return p
    }

    private func focuses(_ p: Prospect) -> Set<StageFocus> {
        Set(StageNavigation.countedFocuses.filter {
            StageNavigation.naturalKeys(for: $0, in: [p], context: StageContext(geo: .none, clients: .none)).count == 1
        })
    }

    // Where a show has GOT TO, which is the question Scout, Prep, Prep blocked and Review each answer.
    // An approved show is also in `.sendApproved`, which asks something else entirely (how many approved
    // emails a disconnected Gmail is holding up), so a bare focus set would make these tests about that
    // too and go red for a reason unrelated to their subject.
    private func lifecycle(_ p: Prospect) -> Set<StageFocus> {
        focuses(p).filter { StageOverlap.family(of: $0) == .lifecycle }
    }

    // MARK: - out of Review while the request stands

    // The issue itself: a redraft is queued on a show whose draft is already in Review, so Prep counts it
    // and Review does not.
    @Test func aDraftedShowWithAReprepQueuedIsCountedByPrepAndNotByReview() {
        let ctx = makeContext()
        let p = show(ctx, key: "reprep-drafted", status: .drafted)
        p.reprepDraftRequested = true

        #expect(lifecycle(p) == [.prep])
    }

    // A contacts-only re-prep is the same answer: the flags are independent, and either one means a run
    // has work queued on this show.
    @Test func anApprovedShowWithAContactsReprepQueuedIsCountedByPrepAndNotByReview() {
        let ctx = makeContext()
        let p = show(ctx, key: "reprep-approved", status: .approved)
        p.reprepContactsRequested = true

        #expect(lifecycle(p) == [.prep])
    }

    // The `.prepBlocked` shape the issue names: a re-prep queued on a drafted show whose night Dan is
    // booked on. The Prep run refuses it, so it is not Prep work yet, and Review must not hold it either.
    @Test func aReprepQueuedShowHeldByADateClashIsCountedByPrepBlockedAndNotByReview() {
        let ctx = makeContext()
        let p = show(ctx, key: "reprep-clash", status: .drafted)
        p.reprepDraftRequested = true
        p.conflictOpen = true

        #expect(lifecycle(p) == [.prepBlocked])
    }

    // The unchanged case, so the rule above cannot be satisfied by emptying Review altogether.
    @Test func aDraftedShowWithNoReprepQueuedStaysInReview() {
        let ctx = makeContext()
        let p = show(ctx, key: "plain-drafted", status: .drafted)

        #expect(lifecycle(p) == [.review])
    }

    // L45, stated as the property rather than as the two cases above: every show that leaves Review for a
    // re-prep lands in exactly one other stage, so none of them can fall out of the queue altogether.
    @Test func everyShowLeavingReviewForAReprepLandsInExactlyOneOtherStage() {
        let ctx = makeContext()
        var made: [Prospect] = []
        for status in [ReviewStatus.drafted, .approved] {
            for (draft, contacts) in [(true, false), (false, true), (true, true)] {
                for clash in [false, true] {
                    let p = show(ctx, key: "\(status.rawValue)-\(draft)-\(contacts)-\(clash)", status: status)
                    p.reprepDraftRequested = draft
                    p.reprepContactsRequested = contacts
                    p.conflictOpen = clash
                    made.append(p)
                }
            }
        }

        for p in made {
            let stages = lifecycle(p)
            #expect(!stages.contains(.review), "\(p.naturalKey) is still counted by Review")
            #expect(stages == [p.conflictOpen ? .prepBlocked : .prep],
                    "\(p.naturalKey) landed in \(stages)")
        }
    }

    // #863: a pill's number is a promise about the rows its tap lands on, so the two are asked of the same
    // mixed store rather than trusted to agree.
    @Test func eachPillsNumberStillEqualsTheRowsItLandsOn() throws {
        let ctx = makeContext()
        show(ctx, key: "plain-drafted", status: .drafted)
        show(ctx, key: "plain-approved", status: .approved)
        show(ctx, key: "kept", status: .queued, hasDraft: false)
        let reprep = show(ctx, key: "reprep", status: .drafted)
        reprep.reprepDraftRequested = true
        let clashed = show(ctx, key: "reprep-clash", status: .approved)
        clashed.reprepContactsRequested = true
        clashed.conflictOpen = true
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let counts = StageNavigation.counts(in: all, context: StageContext(geo: .none, clients: .none))
        for focus in StageNavigation.countedFocuses {
            let rows = StageNavigation.naturalKeys(for: focus, in: all, context: StageContext(geo: .none, clients: .none))
            #expect(counts[focus, default: 0] == rows.count, "\(focus): \(counts[focus] ?? 0) vs \(rows)")
        }
        #expect(Set(StageNavigation.naturalKeys(for: .review, in: all, context: StageContext(geo: .none, clients: .none)))
                == Set(["plain-drafted", "plain-approved"]))
        #expect(Set(StageNavigation.naturalKeys(for: .prep, in: all, context: StageContext(geo: .none, clients: .none))) == Set(["kept", "reprep"]))
        #expect(StageNavigation.naturalKeys(for: .prepBlocked, in: all, context: StageContext(geo: .none, clients: .none)) == ["reprep-clash"])
    }

    // The stage a deep link or a search pick lands on is the same predicate, so a re-prepped show opens on
    // Prep rather than on a Review list that no longer holds it.
    @Test func aReprepQueuedShowDeepLinksToPrepRatherThanReview() throws {
        let ctx = makeContext()
        let p = show(ctx, key: "reprep", status: .drafted)
        p.reprepDraftRequested = true
        try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        #expect(StageNavigation.stage(containing: "reprep", in: all, reachedOutKeys: [], context: StageContext(geo: .none, clients: .none)) == .prep)
    }
}
