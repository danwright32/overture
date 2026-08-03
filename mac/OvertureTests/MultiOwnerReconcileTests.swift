import Testing
import Foundation
import SwiftData

// #888 part B: the multi-owner rule could never fire, so a show listed by TWO sources was permanently
// immune to being marked gone.
//
// FeedReconcile is documented to weigh EVERY owner of a show before believing it is gone: "ANY source
// that reported can prove a show is alive... Only a source whose silence is evidence can take one away."
// everyOwnerWasAskedAndNoneHasIt implements that as `owners.allSatisfy(believable.contains)`.
//
// The wiring could not deliver it. ScoutExtractIngest looped per source and called ScoutService.apply
// once each, and apply called FeedReconcile.reconcile with a SINGLE-element report list. So `believable`
// was never larger than one source, and a show owned by two could never satisfy allSatisfy on any run.
//
// That failed SAFE (nothing was wrongly cancelled), which is why nothing ever broke. But it meant the
// careful part of this design was dead code that read as working, and it would all have switched on at
// once the day somebody batched the reports without knowing what they were arming. So: batched here,
// deliberately, with the multi-owner path actually covered.
//
// ALL of these run through the REAL ingest. Testing FeedReconcile.reconcile directly would prove the rule
// and say nothing about the wiring, which is the exact mistake #887 made (cutting its wire left 1,829
// tests green).
@MainActor
@Suite("A show listed by two sources (#888 part B)")
struct MultiOwnerReconcileTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // A source with enough history that its silence is allowed to count. Anything less and the reconcile
    // is disarmed for an unrelated reason and every test below passes vacuously.
    @discardableResult
    // #897: the baseline matches what these runs actually return (one event each), so a run here is at its
    // source's FULL size and the size gate is wide open. Set it higher and every test below is disarmed for
    // an unrelated reason: a run at half of baseline can no longer mark anything gone (isCredibleNewBaseline,
    // 0.9), so the batching these tests exist to prove would go unproven while they all still passed. The
    // one test that WANTS a degraded source passes its own baseline in, and says so.
    private func establishedSource(_ ctx: ModelContext, _ id: String, baseline: Int = 1) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.pendingContentHash = "new-hash-\(id)"
        s.hasUnreadChanges = true
        s.successfulCheckCount = WatchedSource.warmupRuns
        s.baselineFeedCount = baseline
        ctx.insert(s)
        return s
    }

    // A show BOTH sources listed last time, and neither lists now.
    @discardableResult
    private func coListedShow(_ ctx: ModelContext, owners: [String]) -> Prospect {
        let p = Prospect(naturalKey: "co-listed-show", groupName: "Aurora Strings", discipline: "music",
                         venue: "Merkin Hall", performanceDate: "2099-09-19",
                         sourceListingURL: "https://kaufman.example/aurora", websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.sourceIds = owners
        p.missedScoutCount = 0
        ctx.insert(p)
        return p
    }

    private func event(_ title: String, from sourceId: String) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: "Merkin Hall",
                          performanceDate: "2099-10-01",
                          sourceUrl: "https://\(sourceId).example/\(title)")
    }

    // ONE results file carrying several sources, which is what the batched extract run really produces.
    private func ingest(_ perSource: [(String, [ScoutExtractEvent])], into ctx: ModelContext) {
        let results = ScoutExtractResults(
            version: 1, generatedAt: "2026-07-13T00:00:00Z",
            results: perSource.map { id, events in
                ScoutExtractResult(sourceId: id, verdict: .upcomingListings, events: events, note: nil)
            })
        ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
    }

    // THE case that could never fire. Both owners swept their calendars in this run, both are entirely
    // believable, and neither of them lists the show any more. It is gone, and it may finally be said.
    @Test func bothOwnersSweptAndNeitherHasIt() throws {
        let ctx = try context()
        establishedSource(ctx, "kaufman")
        establishedSource(ctx, "merkin")
        let show = coListedShow(ctx, owners: ["kaufman", "merkin"])

        ingest([("kaufman", [event("Something Else", from: "kaufman")]),
                ("merkin", [event("Another Thing", from: "merkin")])], into: ctx)

        #expect(show.missedScoutCount == 1)
    }

    // The conservative half, and the reason the test above is not simply "cancellation got easier".
    // Kaufman swept and does not have it, but merkin was NOT in this run at all. Merkin might still be
    // listing it. Nothing may be concluded.
    @Test func anOwnerThatWasNeverAskedBlocksTheWholeConclusion() throws {
        let ctx = try context()
        establishedSource(ctx, "kaufman")
        establishedSource(ctx, "merkin")
        let show = coListedShow(ctx, owners: ["kaufman", "merkin"])

        ingest([("kaufman", [event("Something Else", from: "kaufman")])], into: ctx)   // merkin absent

        #expect(show.missedScoutCount == 0)
    }

    // An owner that ran but is too DEGRADED to be trusted about what is missing (#150) is not evidence
    // either. It reported, so it can still prove a show alive; it cannot help take one away.
    @Test func aDegradedOwnerCannotHelpTakeAShowAway() throws {
        let ctx = try context()
        establishedSource(ctx, "kaufman")
        establishedSource(ctx, "merkin", baseline: 20)      // merkin usually lists 20; it returns 1
        let show = coListedShow(ctx, owners: ["kaufman", "merkin"])

        ingest([("kaufman", [event("Something Else", from: "kaufman")]),
                ("merkin", [event("Only One", from: "merkin")])], into: ctx)   // 1 of 20: degraded

        #expect(show.missedScoutCount == 0)
    }

    // Presence beats absence, from ANY source, even one too degraded to be trusted about what is missing.
    // If merkin still lists the show, kaufman dropping it proves nothing.
    @Test func oneOwnerStillListingItProvesItAliveDespiteTheOther() throws {
        let ctx = try context()
        establishedSource(ctx, "kaufman")
        establishedSource(ctx, "merkin")
        let show = coListedShow(ctx, owners: ["kaufman", "merkin"])
        show.missedScoutCount = 1

        ingest([("kaufman", [event("Something Else", from: "kaufman")]),
                ("merkin", [ScoutExtractEvent(title: "Aurora Strings", presenter: "Aurora Strings",
                                              venue: "Merkin Hall", performanceDate: "2099-09-19",
                                              sourceUrl: "https://kaufman.example/aurora")])],
               into: ctx)

        #expect(show.missedScoutCount == 0)
    }

    // A single-owner show must behave exactly as it did before the batching, or this change has quietly
    // altered the common case while claiming to fix the rare one.
    @Test func aSingleOwnerShowIsUnaffectedByTheBatching() throws {
        let ctx = try context()
        establishedSource(ctx, "kaufman")
        let show = coListedShow(ctx, owners: ["kaufman"])

        ingest([("kaufman", [event("Something Else", from: "kaufman")])], into: ctx)

        #expect(show.missedScoutCount == 1)
    }
}
