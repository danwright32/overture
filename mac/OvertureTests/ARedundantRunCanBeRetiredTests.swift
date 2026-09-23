import Testing
import Foundation
import SwiftData

// #2998: a run card that is wholly redundant with the single night cards already in the store.
//
// WHAT SHIPPED, AND WHAT DID NOT. The detection is `Prospect.coverageOfItsOtherNights` and
// `isRetirable` (#3010), and the live store report prints the count on every suite run. The CARD
// control this issue asked for, a sentence plus a one press retire, was built and then removed in the
// same milestone by #4030, which is the stronger answer to the same problem and makes the control
// unreachable: a covering card has this row's title and venue and shares a night with it, which is
// exactly what `ShowLink` groups on, so the covers are members of this row's own group and #4030 draws
// the whole group as ONE card. The retire's own sentence is "every night of this run is already on its
// own card", and after the collapse those cards are not drawn at all.
//
// So what is left to assert here is the RULE, which still answers and is still reported, and the
// SURFACE, where a collapsed group offers nothing because there is nothing left to retire. That was
// found by the combined suite run over both branches, not by either one alone (L85).
@MainActor
@Suite("A run every other card already covers (#2998)")
struct ARedundantRunCanBeRetiredTests {

    private static let venue = "The Cutting Room"
    private static let title = "Steven Maglio & His Big Band Orchestra"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func row(_ ctx: ModelContext, nights: [String], title: String = title) -> Prospect {
        let opening = nights[0]
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title,
                                                            performanceDate: opening,
                                                            venue: Self.venue),
                         groupName: title, discipline: "music", venue: Self.venue,
                         performanceDate: opening, sourceListingURL: nil, priorRelationship: "none",
                         production: "unknown", profile: "unknown", coverage: "unknown", fitScore: 3,
                         tier: "medium", fitReason: "", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nights.count > 1 ? nights.last : nil,
                         partOfRelatedRun: nights.count > 1, runSourceURLs: [], runNights: nights)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func cards(_ ctx: ModelContext) throws -> [QueueItem] {
        QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()),
                         now: Date(timeIntervalSince1970: 1_758_000_000))
    }

    private func byKey(_ ctx: ModelContext) throws -> [String: Prospect] {
        Dictionary(try ctx.fetch(FetchDescriptor<Prospect>()).map { ($0.naturalKey, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    // THE RULE. A run whose every other night is held by a separate SINGLE NIGHT card is redundant with
    // cards that already exist, and the app can see it.
    @Test func arunWhoseOtherNightsAreEachOnTheirOwnCardIsRetirable() throws {
        let ctx = try context()
        let run = row(ctx, nights: ["2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-11-15"])
        row(ctx, nights: ["2026-12-20"])
        let lookup = try byKey(ctx)

        #expect(run.coverageOfItsOtherNights(lookup: { lookup[$0] }) == .fullyCovered)
        #expect(run.isRetirable(lookup: { lookup[$0] }))
    }

    // A RUN COVERED BY ANOTHER RUN is a duplicate rather than a redundant run, which is Dan's rule of
    // 2026-09-21: retiring one of a mutually covering pair and then the other loses the show entirely.
    // The live Steven Maglio shape, where the five night run is covered partly by the four night one.
    @Test func arunCoveredByAnotherRunIsNotRetirable() throws {
        let ctx = try context()
        let big = row(ctx, nights: ["2026-08-16", "2026-09-13", "2026-10-04", "2026-11-15", "2026-12-20"])
        let small = row(ctx, nights: ["2026-09-13", "2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-10-04"])
        row(ctx, nights: ["2026-11-15"])
        row(ctx, nights: ["2026-12-20"])
        let lookup = try byKey(ctx)

        // Both are fully covered, so what separates them is the KIND of card doing the covering.
        #expect(big.coverageOfItsOtherNights(lookup: { lookup[$0] }) == .fullyCovered)
        #expect(small.coverageOfItsOtherNights(lookup: { lookup[$0] }) == .fullyCovered)
        #expect(!big.isRetirable(lookup: { lookup[$0] }),
                "a run covered by another RUN was offered up, and retiring both loses the show")
        #expect(small.isRetirable(lookup: { lookup[$0] }))
    }

    // A PARTLY covered run is not retirable: retiring it would lose the nights nobody else holds. 12
    // runs were in this state on the live store on 2026-09-21 and they are not this issue.
    @Test func apartlyCoveredRunIsNotRetirable() throws {
        let ctx = try context()
        let run = row(ctx, nights: ["2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-11-15"])
        let lookup = try byKey(ctx)

        #expect(run.coverageOfItsOtherNights(lookup: { lookup[$0] }) == .partiallyCovered(covered: 1, of: 2))
        #expect(!run.isRetirable(lookup: { lookup[$0] }))
    }

    // AND THE SURFACE, which is what #4030 settled. Every row above is one same show group, so the queue
    // draws ONE card for all of them: the redundancy this issue is about is not merely noticed, it is
    // gone from the surface, and there is no second card left to retire.
    @Test func thewholeGroupIsOneCardSoThereIsNothingLeftToRetire() throws {
        let ctx = try context()
        row(ctx, nights: ["2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-11-15"])
        row(ctx, nights: ["2026-12-20"])

        let built = try cards(ctx)
        #expect(built.count == 1,
                "three rows of one show are one card since #4030: \(built.map(\.groupName))")
        let card = try #require(built.first)
        #expect(card.collapsedMemberKeys.count == 3,
                "and the one card that is drawn stands for every row behind it")
    }
}
