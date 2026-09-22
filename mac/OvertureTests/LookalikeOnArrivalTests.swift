import Testing
import Foundation
import SwiftData

// #3330: when a show is listed twice, Overture stores it twice, and the only thing that ever joins the
// two is `SameNightTitleVariantMerge` at the NEXT LAUNCH. So Dan meets two cards, pays for two
// reachability checks, and the pairing is invisible until he restarts the app.
//
// THE MEASUREMENT THE ISSUE ASKED FOR IS DONE and is on main as `SameVenueOneNightSweepTests`. Run
// 2026-09-21 over 1,333 rows: 2 same-venue pairs the same-night rule would join, both one show, zero
// wrong. So the rule's false positive count on this population is 0.
//
// DAN'S CALL, 2026-09-21, with that measurement in front of him: **tag the pair, never refuse the
// insert.** The arriving row is still written and is marked as looking like a row already stored.
//
// WHY NOT REFUSE, which is what the issue body asks for. A wrong merge at LAUNCH deletes a row Dan can
// see and the pass logs it. A wrong refusal at INGEST loses a show that never reached a screen and
// leaves nothing to look at, so the failure is invisible by construction. Zero false positives on
// today's store is not evidence about tomorrow's, and that asymmetry does not improve with a better
// measurement (L172, L104).
//
// WHAT TAGGING DOES NOT BUY, stated so it is not rediscovered as a defect (L93): the second card, the
// second paid check and the row a later pass collapses are all still there. What it buys is that the
// pairing is visible the moment the second listing arrives rather than at the next launch, and that
// nothing can ever be lost to a wrong match.
//
// RESOLVED AT READ TIME, never cleared. The tag holds the other row's key, and the note only draws when
// that row is still there, so the launch merge collapsing the pair ends the note by itself. A record
// that excludes something because another covers it has to re-check that other record when it is read,
// or deleting it leaves a claim nobody can see is stale (L200).
@MainActor
@Suite("A show that arrives looking like one already stored (#3330)")
struct LookalikeOnArrivalTests {

    private static let night = "2026-10-06"
    private static let venue = "Merkin Hall"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, _ title: String, night: String = LookalikeOnArrivalTests.night,
                        venue: String = LookalikeOnArrivalTests.venue) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                            venue: venue),
                         groupName: title, discipline: "classical", venue: venue,
                         performanceDate: night, sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func ingest(_ ctx: ModelContext, _ title: String,
                        night: String = LookalikeOnArrivalTests.night,
                        venue: String = LookalikeOnArrivalTests.venue) {
        let e = ExtractedEvent(title: title, presenter: "Kaufman Music Center", venue: venue,
                               performanceDate: night, sourceUrl: "https://example.org/\(title.prefix(6))")
        _ = ScoutService.apply(events: [e], clients: [], history: [], blocked: .empty,
                               today: "2026-09-21", sourceIds: ["kaufmanmusiccenter-org"], into: ctx)
        try? ctx.save()
    }

    private func all(_ ctx: ModelContext) -> [Prospect] {
        (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
    }

    // THE CLAIM. The live pair: pk 598 and pk 1589, one Orli Shaham concert at Merkin Hall on
    // 2026-10-06, two billings, minted eight weeks apart. Both rows survive, and the arriving one knows
    // which row it looked like.
    @Test func anArrivingBillingIsTaggedWithTheRowItLooksLike() throws {
        let ctx = try context()
        let first = stored(ctx, "Orli Shaham, piano")
        ingest(ctx, "Orli Shaham: In Clara's Hands")

        let rows = all(ctx)
        #expect(rows.count == 2, "tagging must never cost a row: \(rows.map(\.groupName).sorted())")
        let arrived = try #require(rows.first { $0.groupName == "Orli Shaham: In Clara's Hands" })
        #expect(arrived.arrivedLookingLike == first.naturalKey,
                "the arriving row carries no tag, so the pairing is invisible until the next launch")
    }

    // The precondition, so a green above cannot come from a fixture the rule would have refused anyway
    // (L159). This is the predicate `SameNightTitleVariantMerge.clusters` calls, and the whole licence
    // for tagging is that the same judgement is already trusted enough to DELETE rows with.
    @Test func theSameNightRuleReallyDoesCallThatPairOneShow() {
        #expect(GroupNameMatch.isSameNightVariant("Orli Shaham, piano", "Orli Shaham: In Clara's Hands"))
    }

    // WHAT MUST NOT BE TAGGED (L104). Two genuinely different shows in one room on one night are two
    // shows, and a tag claiming otherwise would be the sentence the card least deserves.
    @Test func aDifferentShowOnTheSameNightIsNotTagged() throws {
        let ctx = try context()
        stored(ctx, "Orli Shaham, piano")
        ingest(ctx, "Danish String Quartet")

        let arrived = try #require(all(ctx).first { $0.groupName == "Danish String Quartet" })
        #expect(arrived.arrivedLookingLike == nil,
                "an unrelated show was tagged as a lookalike, which is the claim this must never make")
    }

    // A DIFFERENT NIGHT is a different engagement, whatever the title says. The launch merge is same
    // night only, for the reason its own header gives: two nights of one show are a RUN, and widening
    // this would claim a duplicate where there is a second performance.
    @Test func theSameBillingOnAnotherNightIsNotTagged() throws {
        let ctx = try context()
        stored(ctx, "Orli Shaham, piano")
        ingest(ctx, "Orli Shaham: In Clara's Hands", night: "2026-10-07")

        let arrived = try #require(all(ctx).first { $0.groupName == "Orli Shaham: In Clara's Hands" })
        #expect(arrived.arrivedLookingLike == nil, "a second night was tagged as a duplicate of the first")
    }

    // A DIFFERENT VENUE is not tagged either, and this is the one place this rule is deliberately
    // NARROWER than the launch merge. That pass is venue blind since #1761, on Dan's rule that one title
    // on one night is one pitch whatever the rooms say (#4117, reaffirmed 2026-09-21). Here the cost of
    // being wrong lands on a card Dan has not seen yet rather than on a row he can, so this asks for the
    // venue too. Stating the difference rather than sharing a predicate that answers a different
    // question (L342).
    @Test func theSameBillingAtAnotherVenueIsNotTagged() throws {
        let ctx = try context()
        stored(ctx, "Orli Shaham, piano")
        ingest(ctx, "Orli Shaham: In Clara's Hands", venue: "Zankel Hall")

        let arrived = try #require(all(ctx).first { $0.groupName == "Orli Shaham: In Clara's Hands" })
        #expect(arrived.arrivedLookingLike == nil, "a show at another venue was tagged as a duplicate")
    }

    // A row that arrives with nothing like it carries no tag, which is the ordinary case and the one a
    // rule that tagged everything would still pass (L104).
    @Test func aShowWithNothingLikeItCarriesNoTag() throws {
        let ctx = try context()
        ingest(ctx, "Orli Shaham, piano")

        let arrived = try #require(all(ctx).first)
        #expect(arrived.arrivedLookingLike == nil)
    }

    // THE SENTENCE, and the read-time resolution that decides whether it is said at all.
    //
    // Dan's wording, chosen 2026-09-21 with the alternatives in front of him: name the other show, and
    // do not use the word "billing", which appears nowhere else in what the app says to him.
    @Test func theCardNamesTheShowThisOneLooksLike() {
        let ctx = try! context()
        var item = QueueItem(stored(ctx, "Orli Shaham: In Clara's Hands"))
        item.arrivedLookingLikeTitle = "Orli Shaham, piano"
        #expect(QueueModel.arrivedLookingLikeNote(item)
                    == "Looks like the same show as Orli Shaham, piano, already stored for this night.")
    }

    // The note is resolved at READ time, so a card whose lookalike has since been collapsed by the launch
    // merge says NOTHING rather than naming a row that is no longer stored. Nothing clears the field; the
    // absence of the row is what ends the sentence (L200).
    @Test func aCardWhoseLookalikeIsGoneSaysNothing() {
        let ctx = try! context()
        var item = QueueItem(stored(ctx, "Orli Shaham: In Clara's Hands"))
        item.arrivedLookingLikeTitle = nil
        #expect(QueueModel.arrivedLookingLikeNote(item) == nil)
        item.arrivedLookingLikeTitle = ""
        #expect(QueueModel.arrivedLookingLikeNote(item) == nil,
                "an empty title drew a sentence naming nothing")
    }
}
