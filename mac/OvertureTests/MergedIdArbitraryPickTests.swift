import Testing
import Foundation
import SwiftData

// #4040: `matchByConcertIdentity`'s merged branch returns `sharing.first` over an UNORDERED fetch.
//
// The branch two lines below it is deliberately deterministic and its comment says exactly why:
//
//   Deterministic, never `first` on an unordered fetch. Today's store already holds four rows sharing
//   one id, so an arbitrary pick would land Dan's dismissal on a different row each sweep.
//
// The merged branch does precisely what that comment forbids, and it does so with NO corroboration at
// all: no title test and no run overlap, on the strength of a claim in the arm's header that a
// synthetic id "can NEVER fuse two genuinely different shows".
//
// WHAT WAS MEASURED BEFORE WRITING THIS, 2026-09-20, because the claim deserved deriving rather than
// reading (L681, and this milestone's own record of premises wrong about the mechanism):
//
//   - The MINTING premise HOLDS. `SameDateVenueMerge.seriesPrefix` is constructed in exactly one place,
//     `syntheticSeriesId`, called from exactly one place, `stamped`, called from exactly one place,
//     `ScoutExtractIngest.swift:124`, and that call is gated on `source.mergeSameDateVenue`. One of the
//     74 watched sources carries that flag.
//   - So the safety rests on a HUMAN decision on the watchlist rather than on a property of the code.
//     A venue that genuinely runs two different shows a night, flagged that way, is fused with no title
//     check, because date plus venue is the whole of the id.
//   - The live store holds 9 rows carrying a synthetic id and NO id held by more than one row, so the
//     arbitrary pick is inert TODAY. That is a fact about today and not a property: it holds only while
//     the same-date-venue collapse never leaves two rows behind, which is #2998's whole subject.
//
// So this suite pins the ORDERING, which is a defect whatever the answer to the fusing question, and it
// is the half that can be fixed without deciding the human one (L343, L419).
@MainActor
@Suite("A merged same date venue id picks deterministically (#4040)")
struct MergedIdArbitraryPickTests {

    private static let venue = "Weill Recital Hall"
    private static let night = "2026-11-14"
    private static var mergedId: String {
        SameDateVenueMerge.syntheticSeriesId(date: night, venue: venue)
    }

    private func context() throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self])
        return ModelContext(try ModelContainer(for: schema,
                            configurations: [ModelConfiguration(schema: schema,
                                                                isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, title: String, dismissed: Bool = false) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: title, performanceDate: Self.night,
                                          venue: Self.venue)
        let p = Prospect(naturalKey: key, groupName: title, discipline: "music", venue: Self.venue,
                         performanceDate: Self.night, sourceListingURL: nil,
                         priorRelationship: "none", production: "unknown", profile: "unknown",
                         coverage: "unknown", fitScore: 3, tier: "medium", fitReason: "",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         runEndDate: nil, partOfRelatedRun: false, runSourceURLs: [],
                         runNights: [Self.night])
        p.seriesId = Self.mergedId
        if dismissed { p.markDismissed(reason: .dontWantToShoot) }
        ctx.insert(p)
        return p
    }

    // The precondition, asserted so a pass here can never come from a fixture where the branch was not
    // reached at all (L159). Both stored rows must carry an id the merged branch accepts, and the
    // incoming row must hold that same id, or the chain answers on a different arm entirely.
    @Test func theFixtureReallyDoesUseAnIdTheMergedBranchAccepts() {
        #expect(SameDateVenueMerge.isMerged(Self.mergedId))
        #expect(Self.mergedId.hasPrefix("samedatevenue:"))
    }

    // THE CLAIM, and the two earlier versions of this test are recorded here rather than quietly
    // replaced, because each was green while proving nothing.
    //
    // The first asserted that exactly ONE row ends up dismissed. True whichever row the pick lands on:
    // re-keying the dismissed row leaves it dismissed under a new title, re-keying the other leaves the
    // dismissal where it was. One dismissal either way (L159).
    //
    // The second compared the two insertion orders and asserted they agree. That DID catch it, with
    // `outcomes[0] -> true, outcomes[1] -> false`, and the message read: with the dismissed row inserted
    // first the incoming show came out DISMISSED, and inserted second it came out live. But it was
    // INTERMITTENT, red on two runs of four, because an unordered fetch is genuinely arbitrary rather
    // than merely unspecified, so as a permanent guard it would have been a flake (L293).
    //
    // So this asserts the RULE instead, in both insertion orders: the row carrying outreach history is
    // the one the merged branch takes, which is what the sibling branch has always guaranteed. That is
    // deterministic once the code is, and it fails on any return to an arbitrary pick.
    @Test func theRowCarryingOutreachHistoryIsTheOneTaken() throws {
        for historyFirst in [true, false] {
            let ctx = try context()
            // Insertion order is the only lever a test has over an unordered fetch, so the rule is
            // checked BOTH ways round: a rule that holds for one order is the defect, not the fix.
            var reached: Prospect
            if historyFirst {
                reached = stored(ctx, title: "Jinhyung Park", dismissed: true)
                stored(ctx, title: "Charu Suri Quartet")
            } else {
                stored(ctx, title: "Charu Suri Quartet")
                reached = stored(ctx, title: "Jinhyung Park", dismissed: true)
            }
            // A dismissal alone is what `hasOutreachHistory` counts, and it is what Dan would lose.
            #expect(NaturalKeyVenueMigration.hasOutreachHistory(reached),
                    "the fixture's marked row does not satisfy the rule under test, so it measures nothing")
            let otherTitle = "Charu Suri Quartet"
            try ctx.save()

            let incoming = ExtractedEvent(title: "An Evening of Piano", presenter: "Carnegie Hall",
                                          venue: Self.venue, performanceDate: Self.night,
                                          sourceUrl: nil, seriesId: Self.mergedId)
            _ = ScoutService.apply(events: [incoming], clients: [], history: [], blocked: .empty,
                                   today: "2026-10-01", sourceIds: ["carnegiehall-org"], into: ctx)
            try ctx.save()

            let rows = try ctx.fetch(FetchDescriptor<Prospect>())
            // The branch has to have FIRED, or everything below agrees trivially. A re-key leaves TWO
            // rows; an insert leaves THREE, and three means this suite is about a path never taken.
            #expect(rows.count == 2,
                    Comment(rawValue: "expected a re-key leaving 2 rows, got \(rows.count): "
                            + "\(rows.map(\.groupName).sorted())"))

            // The row WITHOUT history must be untouched, whatever the order. Asked this way round
            // rather than by naming the winner, because it is the half that costs Dan something: if the
            // pick took the other row, his refusal of one act is now attached to a show he never saw.
            let untouched = rows.first { $0.groupName == otherTitle }
            #expect(untouched != nil,
                    Comment(rawValue: "with history inserted \(historyFirst ? "first" : "second"), the "
                            + "row carrying NO history was re-keyed onto the incoming show and the "
                            + "dismissal moved with the other one"))
        }
    }

    // AND A DETERMINISTIC GUARD BESIDE THE BEHAVIOURAL ONE, because the behavioural one is only
    // PROBABILISTIC and saying so is the point.
    //
    // Measured 2026-09-20 with `scripts/mutate.sh`, restoring the arbitrary pick three times: CAUGHT,
    // SURVIVED, CAUGHT. The test above can only see the defect when the arbitrary order happens to
    // differ from the rule in at least one of the two insertion orders, and sometimes it does not. A
    // guard that catches a regression two times in three is not a guard (L1), and making the fixture
    // bigger only moves the odds.
    //
    // The pairing was then measured rather than assumed. Restoring the arbitrary pick three more
    // times with both guards present: CAUGHT, CAUGHT, CAUGHT. On the second of those the
    // behavioural test PASSED and this guard was the only thing that went red, which is the
    // clearest possible evidence that it is carrying the weight rather than duplicating it.
    //
    // The property is expressible over the source exactly, so it is asserted there: the merged branch
    // must not hand back a bare `first` on the fetch. Same pattern as
    // `ScoutUpsertTargetTests.theRealLookupsDoNotSwallowAFailedRead`, which exists for the same reason,
    // that the thing worth pinning is not reachable any other way.
    @Test func theMergedBranchDoesNotReturnABareFirstOnTheFetch() {
        let source = SourceGuardHelper.source("Overture/Integration/ScoutService.swift")
        #expect(!source.isEmpty, "the guard read no source, so the check below passes on nothing")

        // #4040 (the namespace half): the branch is now ANCHORED to the row, so the locator names the
        // anchored call. REPOINTED rather than loosened to a prefix, for the reason the #4074 note below
        // gives: a locator that stops naming one exact declaration starts matching whatever else grows
        // near it, and an aim is a locator rather than a pattern.
        guard let branch = source.range(
            of: "if SameDateVenueMerge.isMerged(seriesId, naming: openingNight, venue: venue)") else {
            Issue.record("the merged branch is no longer declared where this guard looks")
            return
        }
        // To the end of the branch, which is the closing brace of the `if`. Bounded by the next
        // statement rather than by a line count, so a comment added inside it cannot break the guard
        // or silently shrink what it reads (L518).
        let after = source[branch.lowerBound...]
        let body = after.range(of: "\n        let corroborated").map { String(after[..<$0.lowerBound]) }
            ?? String(after.prefix(2000))

        #expect(!body.contains("return sharing.first }"),
                "the merged branch returns a bare first on an unordered fetch again (#4040)")

        // #4074 MOVED the pick out of this branch and into one named function both branches call, so the
        // rule is no longer spelled here and a check for `hasOutreachHistory` in this body went red. That
        // red was CORRECT and is the reason this is repointed rather than relaxed: a guard whose subject
        // moves out from under it stops covering anything, and the cheap way out is to delete the
        // assertion, which turns the complaint green while removing the coverage (L708).
        //
        // So the branch must DELEGATE, and the thing it delegates to must carry the rule.
        #expect(body.contains("theOnlyRowThisMayReKey"),
                """
                the merged branch no longer delegates to the one function that owns this pick, so \
                whatever it does now is unguarded by the two assertions below
                """)

        guard let picker = source.range(of: "private static func theOnlyRowThisMayReKey") else {
            Issue.record("the function the merged branch delegates its pick to is gone (#4074)")
            return
        }
        let pickerBody = String(source[picker.lowerBound...].prefix(1_400))
        #expect(pickerBody.contains("hasOutreachHistory"),
                "the pick no longer prefers the row carrying Dan's history, so it is arbitrary again")
        #expect(pickerBody.contains("guard withHistory.count <= 1"),
                """
                the refusal is gone, so two stored rows both carrying history are picked between \
                arbitrarily and one of them is re-keyed onto the incoming show (#4074, #797)
                """)
    }
}
