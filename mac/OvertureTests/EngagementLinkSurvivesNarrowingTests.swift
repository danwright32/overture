import Testing
import Foundation
import SwiftData

// #3652 (milestone #80, Phase 2): the cross-venue engagement link must survive the derivation narrowing.
//
// WHAT IT IS. When one production plays several venues or nights, each row carries "this also plays at X",
// built by `EngagementLink.group`, which clusters every row it is handed by normalised title and date
// proximity and hands each row back the OTHER members of its cluster. It can only link what it can see.
//
// WHY THIS GUARD EXISTS BEFORE THE CHANGE IT GUARDS. Inside `QueueModel.items`, three whole-corpus tables
// are deliberately built from `corpus ?? prospects` and each says why in its own comment: a dismissal must
// not quietly change which organisation names draw, or take an organisation under the bar. `linked` was
// built from `prospects`, the rows being BUILT, and carried no reason at all. An entry with no written
// reason beside three that each carry one is evidence it was never reasoned about (L233), and it is
// filed as #3644.
//
// It does not bite today, because `prospects` is the whole queue scope. Milestone #80's Phase 4 (#3654)
// narrows exactly that argument to the rows on screen. At that moment a show whose sibling engagement
// sits in another stage silently stops saying it plays anywhere else, and NOTHING would report it: the
// note simply does not draw, which is indistinguishable from a production that really does play once
// (L98). So the guard lands before the change, not with it.
@MainActor
@Suite("A cross-venue engagement stays linked when the derivation narrows (#3652)")
struct EngagementLinkSurvivesNarrowingTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, venue: String, date: String,
                      status: ReviewStatus) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "The Same Production", discipline: "music",
                         venue: venue, performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "presenter", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.presenter = "The Same Production Presents"
        p.location = "New York, NY"
        ctx.insert(p)
        return p
    }

    // The POSITIVE CONTROL, first, because every assertion below is only meaningful if these two rows
    // link to each other at all (L171). One production, two venues, three nights apart.
    @Test func twoEngagementsOfOneProductionLinkToEachOther() throws {
        let ctx = ModelContext(try container())
        let scout = show(ctx, key: "at-weill", venue: "Weill Recital Hall", date: "2026-10-01", status: .new)
        let reached = show(ctx, key: "at-merkin", venue: "Merkin Hall", date: "2026-10-04", status: .contacted)
        try ctx.save()

        let rows = [scout, reached]
        let items = QueueModel.items(from: rows, corpus: rows)

        let scoutItem = items.first(where: { $0.id == "at-weill" })
        let reachedItem = items.first(where: { $0.id == "at-merkin" })
        #expect(scoutItem?.linkedEngagementMembers.isEmpty == false,
                "the two engagements did not link at all, so nothing below measures narrowing")
        #expect(reachedItem?.linkedEngagementMembers.isEmpty == false,
                "the two engagements did not link at all, so nothing below measures narrowing")
    }

    // THE GUARD. The rows being BUILT are narrowed to one stage, while the full row set is still handed
    // in. The link must survive, because the sibling is still in the store and still in the pass's own
    // scope; it is merely not on the screen.
    @Test func aSiblingInAnotherStageStillLinksWhenOnlyOneStageIsBuilt() throws {
        let ctx = ModelContext(try container())
        let scout = show(ctx, key: "at-weill", venue: "Weill Recital Hall", date: "2026-10-01", status: .new)
        let reached = show(ctx, key: "at-merkin", venue: "Merkin Hall", date: "2026-10-04", status: .contacted)
        try ctx.save()

        let everything = [scout, reached]
        // What Phase 4 does: build cards for one stage's rows only.
        let onScreen = [scout]

        let items = QueueModel.items(from: onScreen, corpus: everything, rowsForLinking: everything)

        let scoutItem = items.first(where: { $0.id == "at-weill" })
        #expect(scoutItem != nil, "the row being built is not in the result, so nothing was measured")
        #expect(scoutItem?.linkedEngagementMembers.isEmpty == false,
                Comment(rawValue: "the show on screen no longer says it also plays elsewhere, because the "
                        + "linking was built from the narrowed rows rather than the full set. Nothing "
                        + "reports this: the note simply does not draw, which reads exactly like a "
                        + "production that plays once (#3652, #3644, L98)."))
        #expect(scoutItem?.linkedEngagementMembers.contains(where: { $0.venue == "Merkin Hall" }) == true,
                Comment(rawValue: "the link is there but does not name the sibling venue, so the row "
                        + "cannot say where else the production plays."))
    }

    // AND THE BEHAVIOUR THAT IS DELIBERATELY UNCHANGED, recorded so the next reader does not "fix" it.
    // A sibling on a DISMISSED row is invisible today, because `prospects` is the queue scope and
    // dismissed rows are not in it. That is a product question rather than a performance one, and this
    // phase deliberately does not answer it: `rowsForLinking` defaults to the rows being built, so
    // nothing changes for any caller that does not pass it.
    @Test func theDefaultLeavesEveryExistingCallerExactlyAsItWas() throws {
        let ctx = ModelContext(try container())
        let scout = show(ctx, key: "at-weill", venue: "Weill Recital Hall", date: "2026-10-01", status: .new)
        let reached = show(ctx, key: "at-merkin", venue: "Merkin Hall", date: "2026-10-04", status: .contacted)
        try ctx.save()

        let onScreen = [scout]
        // No `rowsForLinking`, which is every call site in the tree today.
        let items = QueueModel.items(from: onScreen, corpus: [scout, reached])

        #expect(items.first?.linkedEngagementMembers.isEmpty == true,
                Comment(rawValue: "a caller that did not ask for a wider linking set got one anyway, so "
                        + "this change is not the no-op for existing callers that it claims to be."))
    }
}
