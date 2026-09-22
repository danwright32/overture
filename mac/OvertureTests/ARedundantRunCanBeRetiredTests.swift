import Testing
import Foundation
import SwiftData

// #2998: a run card whose every other night is already held by a single night card of its own.
//
// A weekly or recurring series is routinely stored BOTH as a run carrying every night AND as separate
// cards for the individual nights, so the run card can be entirely redundant with cards that already
// exist. Dan meets that as two cards for one show plus a dismiss that refuses.
//
// THE DETECTION HAS BEEN HERE SINCE #3010 (`Prospect.coverageOfItsOtherNights` and `isRetirable`, both
// asked through `dropNight`'s own collision check so the detector and the drop cannot disagree). What
// was missing was the card saying so and the one press.
//
// WHY IT SHIPS NOW AND NOT IN SEPTEMBER. The live count was ZERO on 2026-09-20 and the control was
// deliberately held, because one built for a state nobody is in ships inert and nothing says so (L543).
// Measured on the live store 2026-09-22 through `FullyCoveredRunLiveStoreTests`: 3 fully covered runs, 1
// of them retirable, the Steven Maglio run at The Cutting Room.
//
// DAN'S CALL, 2026-09-22, with the three options and their worst case in front of him: the press
// DISMISSES the run as a duplicate, so it leaves the queue and comes back from the Archive like any
// dismissal. Nothing is deleted.
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

    // THE CLAIM. The run's other two nights are each held by their own single night card, so the run
    // card says so.
    @Test func aRunWhoseOtherNightsAreEachOnTheirOwnCardSaysSo() throws {
        let ctx = try context()
        let run = row(ctx, nights: ["2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-11-15"])
        row(ctx, nights: ["2026-12-20"])

        let card = try #require(try cards(ctx).first { $0.id == run.naturalKey })
        #expect(card.everyOtherNightIsOnItsOwnCard)
        #expect(QueueModel.everyNightCoveredNote(card)
                == "Every night of this run is already on its own card.")
    }

    // THE PRECONDITION, so a green above cannot come from a fixture the domain rule would have answered
    // whatever the card did (L159). This is the app's own predicate, unchanged by this issue.
    @Test func theFixtureIsOneTheDomainRuleCallsRetirable() throws {
        let ctx = try context()
        let run = row(ctx, nights: ["2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-11-15"])
        row(ctx, nights: ["2026-12-20"])
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let byKey = Dictionary(stored.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })

        #expect(run.coverageOfItsOtherNights(lookup: { byKey[$0] }) == .fullyCovered)
        #expect(run.isRetirable(lookup: { byKey[$0] }))
    }

    // A RUN COVERED BY ANOTHER RUN is a DUPLICATE, not a redundant run, and gets no control. Dan's rule
    // of 2026-09-21: retiring one of a mutually covering pair and then the other loses the show entirely.
    //
    // THE FIXTURE IS THE LIVE SHAPE, the Steven Maglio pair measured on 2026-09-21, and it has to be:
    // the pair this test was first written with was not fully covered at all (the shorter run holds its
    // own nights under ONE key, so the longer run's remaining nights were never all held), so the rule
    // under test never decided anything and a mutation removing it SURVIVED (L159). Here the five night
    // run's other nights are held by the four night run AND by single night cards, which is what makes
    // the answer turn on whether a cover is itself a run.
    @Test func aRunCoveredByAnotherRunOffersNothingWhileItsSubsetRunDoes() throws {
        let ctx = try context()
        let big = row(ctx, nights: ["2026-08-16", "2026-09-13", "2026-10-04", "2026-11-15", "2026-12-20"])
        let small = row(ctx, nights: ["2026-09-13", "2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-10-04"])
        row(ctx, nights: ["2026-11-15"])
        row(ctx, nights: ["2026-12-20"])

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let byKey = Dictionary(stored.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
        // The precondition the claim rests on: BOTH runs are fully covered, so what separates them is
        // the kind of card doing the covering and nothing else.
        #expect(big.coverageOfItsOtherNights(lookup: { byKey[$0] }) == .fullyCovered)
        #expect(small.coverageOfItsOtherNights(lookup: { byKey[$0] }) == .fullyCovered)

        let built = try cards(ctx)
        let bigCard = try #require(built.first { $0.id == big.naturalKey })
        #expect(!bigCard.everyOtherNightIsOnItsOwnCard,
                "a run covered by another RUN offered a retire, and pressing both loses the show")
        #expect(QueueModel.everyNightCoveredNote(bigCard) == nil)

        let smallCard = try #require(built.first { $0.id == small.naturalKey })
        #expect(smallCard.everyOtherNightIsOnItsOwnCard,
                "the run whose nights are each on a single night card is the one this issue is about")
    }

    // A PARTLY covered run says nothing. 14 runs were in this state on 2026-09-20 and they are not this
    // issue: retiring one would lose the nights nobody else holds.
    @Test func apartlyCoveredRunSaysNothing() throws {
        let ctx = try context()
        let run = row(ctx, nights: ["2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-11-15"])

        let card = try #require(try cards(ctx).first { $0.id == run.naturalKey })
        #expect(!card.everyOtherNightIsOnItsOwnCard)
    }

    // AND A SINGLE NIGHT CARD is not a run at all, which is almost every row in the store.
    @Test func asingleNightCardSaysNothing() throws {
        let ctx = try context()
        let only = row(ctx, nights: ["2026-10-04"])

        let card = try #require(try cards(ctx).first { $0.id == only.naturalKey })
        #expect(!card.everyOtherNightIsOnItsOwnCard)
        #expect(QueueModel.everyNightCoveredNote(card) == nil)
    }

    // THE PRESS. It goes through the same path the dismiss menu uses, with the reason the store already
    // has, so the row leaves the queue and can be restored exactly as any dismissal can.
    @Test func retiringTheRunDismissesItAsADuplicateAndItCanComeBack() throws {
        let ctx = try context()
        let run = row(ctx, nights: ["2026-10-04", "2026-11-15", "2026-12-20"])
        row(ctx, nights: ["2026-11-15"])
        row(ctx, nights: ["2026-12-20"])
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let card = try #require(try cards(ctx).first { $0.id == run.naturalKey })
        let feedback = ActionFeedback()

        #expect(ProspectMutations.recordOutcome(card, .duplicate, prospects: stored, context: ctx,
                                                feedback: feedback),
                "the reason the control passes must be one the outcome recorder accepts")
        #expect(run.status == .dismissed)
        #expect(run.showOutcome == .duplicate)

        // And back again, which is what makes the one press safe to offer: the Archive's own restore,
        // the same one every other dismissal comes back through (#28).
        DismissedProspects.restore(run)
        #expect(run.status != .dismissed)
        #expect(run.showOutcome == nil, "a restored row must not keep the ending it was dismissed with")
    }
}
