import Testing
import Foundation
import SwiftData
@testable import Overture

// #1567: "is this show showable in the Queue" was answered in two places that disagreed.
//
// The issue read it as the Scout PILL over-counting against its own list. It does not: the stage list
// is built from StageNavigation.focusedKeys (QueueView filters the raw items by them), so the pill's
// number and the rows a tap lands on have always matched. The divergence was between the stage lists
// and the two surfaces that went through QueueModel.queueOrder instead: the masthead total, and the
// deep-link routing that decides whether a global search pick or an OmniFocus tap opens the Queue or
// Archive. Measured on the live store on 2026-07-26, they disagreed about 137 of 589 untriaged shows.
//
// The user-visible half was the routing. A show sitting in Dan's Scout list, 131 of which were beyond
// queueOrder's 90-day window, sent him to ARCHIVE when he searched for it, which reads as "this show
// is gone" about a row he can see. So both surfaces now ask StageNavigation, the same predicate the
// lists render from, and this suite is what holds them to it.
@MainActor
@Suite("One filter answers whether the Queue will show a lead (#1567)")
struct QueueShowableIsOneFilterTests {
    private let today = ScoutTestClock.stageNavigationAnchor   // 2026-07-12
    private let now = Date(timeIntervalSince1970: 1_768_000_000)

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, status: ReviewStatus = .new,
                      date: String = "2026-08-19") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        ctx.insert(p)
        return p
    }

    private func all(_ ctx: ModelContext) throws -> [Prospect] {
        try ctx.fetch(FetchDescriptor<Prospect>())
    }

    // The rows the Scout stage actually puts on screen.
    private func scoutRows(_ ps: [Prospect]) -> [String] {
        StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: ps, today: today, now: now)
    }

    private func opens(_ ps: [Prospect], _ key: String, reachedOut: Set<String> = []) -> Bool {
        StageNavigation.opensInQueue(key: key, in: ps, reachedOutKeys: reachedOut,
                                     today: today, now: now)
    }

    private func inAStage(_ ps: [Prospect], _ key: String, reachedOut: Set<String> = []) -> Bool {
        StageNavigation.stage(containing: key, in: ps, reachedOutKeys: reachedOut,
                              today: today, now: now) != nil
    }

    // MARK: - The invariant

    // The whole rule in one test, over a store holding a show of every kind: a lead opens the Queue if
    // and only if some stage will render it. No second filter gets a say.
    @Test func aLeadOpensTheQueueExactlyWhenAStageWillRenderIt() throws {
        let ctx = try context()
        show(ctx, "near", date: "2026-08-19")                        // inside the old 90-day window
        show(ctx, "far-future", date: "2027-03-01")                  // ~232 days out, outside it
        show(ctx, "to-review", status: .drafted, date: "2027-03-01") // in a stage AND outside it
        show(ctx, "contacted-quiet", status: .contacted)             // no stage renders this
        show(ctx, "cut", status: .dismissed)

        let ps = try all(ctx)
        for p in ps {
            let rendered = inAStage(ps, p.naturalKey)
            let opened = opens(ps, p.naturalKey)
            #expect(opened == rendered,
                    "\(p.naturalKey): the Queue opens \(opened) but a stage renders it \(rendered)")
        }
    }

    // MARK: - The show Dan can see

    // The #1567 case. A show past the old 90-day window is still untriaged work and the Scout list
    // renders it, so searching for it must land him ON it. It used to route to Archive, which says
    // "gone" about a row that is right there.
    @Test func aFarFutureUntriagedShowTheScoutListRendersOpensInTheQueue() throws {
        let ctx = try context()
        show(ctx, "far-future", date: "2027-03-01")

        let ps = try all(ctx)
        #expect(scoutRows(ps) == ["far-future"])
        #expect(opens(ps, "far-future"))
    }

    // Same shape, different rule: queueOrder hid a still-untriaged show that had dropped out of the
    // feed (#133), while the Scout list shows it struck through and still offers Keep and Dismiss.
    // The list is the one telling the truth, so the routing follows it.
    @Test func aShowGoneFromTheFeedThatScoutStillRendersOpensInTheQueue() throws {
        let ctx = try context()
        let gone = show(ctx, "gone")
        gone.missedScoutCount = FeedReconcile.goneThreshold
        try ctx.save()

        let ps = try all(ctx)
        #expect(gone.disappearedFromFeed)
        #expect(scoutRows(ps) == ["gone"])
        #expect(opens(ps, "gone"))
    }

    // A show that is in a stage is reachable however far out it is: the stage list has no date window
    // at all, so a drafted show a year away is real work waiting on Dan.
    @Test func aDraftedShowBeyondTheOldWindowOpensInTheQueue() throws {
        let ctx = try context()
        show(ctx, "drafted-far", status: .drafted, date: "2027-03-01")

        #expect(opens(try all(ctx), "drafted-far"))
    }

    // MARK: - The dead ends that must stay closed

    // The other direction, and a bug this closes that #1567 did not mention: a contacted show with no
    // send problem is in NO stage, but the old filter let it through on its date alone. Dan landed in
    // the Queue on a list that then rendered nothing. That is #792's dead end in a third place.
    @Test func aContactedShowNoStageRendersDoesNotOpenTheQueue() throws {
        let ctx = try context()
        show(ctx, "contacted-quiet", status: .contacted)

        let ps = try all(ctx)
        #expect(scoutRows(ps).isEmpty)
        #expect(opens(ps, "contacted-quiet") == false)
    }

    // #628 must survive the change: a dismissed show never renders in the Queue, so it opens Archive.
    @Test func aDismissedShowNeverOpensTheQueue() throws {
        let ctx = try context()
        show(ctx, "cut", status: .dismissed)

        #expect(opens(try all(ctx), "cut") == false)
    }

    // A key naming no show at all (an OmniFocus task outliving its prospect) is not reachable, rather
    // than opening the Queue on nothing.
    @Test func aKeyNoShowAnswersToDoesNotOpenTheQueue() throws {
        let ctx = try context()
        show(ctx, "real")

        #expect(opens(try all(ctx), "ghost") == false)
    }

    // Carried over from the retired QueueReachabilityTests: a show whose run is over and that Dan never
    // pitched has left triage (#861/#864), so nothing renders it and it opens Archive.
    @Test func aPastShowNobodyPitchedDoesNotOpenTheQueue() throws {
        let ctx = try context()
        show(ctx, "went-by", date: "2020-01-01")

        let ps = try all(ctx)
        #expect(scoutRows(ps).isEmpty)
        #expect(opens(ps, "went-by") == false)
    }

    // Reached-out is a stage too, and its rows are per-recipient rather than queue rows, so a show Dan
    // has pitched opens the Queue however long past its date is (#628's late-reply case).
    @Test func aReachedOutShowOpensTheQueueEvenLongPast() throws {
        let ctx = try context()
        show(ctx, "pitched", status: .contacted, date: "2020-01-01")

        #expect(opens(try all(ctx), "pitched", reachedOut: ["pitched"]))
    }

    // MARK: - The masthead

    // The masthead's "N in the queue" now counts exactly the shows the stages hold, so it can no longer
    // read lower than the pill sitting directly beneath it. On the live store that was 452 against 589.
    @Test func theMastheadCountsExactlyTheShowsTheStagesRender() throws {
        let ctx = try context()
        show(ctx, "near", date: "2026-08-19")
        show(ctx, "far-future", date: "2027-03-01")
        show(ctx, "to-review", status: .drafted)
        show(ctx, "contacted-quiet", status: .contacted)
        show(ctx, "cut", status: .dismissed)

        let keys = StageNavigation.queueKeys(in: try all(ctx), reachedOutKeys: [],
                                             today: today, now: now)

        #expect(keys == ["near", "far-future", "to-review"])
    }

    // Reached-out leads out of the count, as they always were: the masthead line is about work still to
    // send, and the Reached-out stage has its own pill and its own per-recipient rows.
    @Test func theMastheadCountLeavesOutTheShowsAlreadyPitched() throws {
        let ctx = try context()
        show(ctx, "near")
        show(ctx, "pitched", status: .contacted)

        let keys = StageNavigation.queueKeys(in: try all(ctx), reachedOutKeys: ["pitched"],
                                             today: today, now: now)

        #expect(keys == ["near"])
    }

    // The two surfaces are one predicate, so they cannot answer differently: every show the masthead
    // counts opens the Queue when Dan searches for it.
    @Test func everyShowTheMastheadCountsOpensTheQueue() throws {
        let ctx = try context()
        show(ctx, "near", date: "2026-08-19")
        show(ctx, "far-future", date: "2027-03-01")
        show(ctx, "to-review", status: .drafted)
        show(ctx, "contacted-quiet", status: .contacted)
        show(ctx, "cut", status: .dismissed)

        let ps = try all(ctx)
        for key in StageNavigation.queueKeys(in: ps, reachedOutKeys: [], today: today, now: now) {
            #expect(opens(ps, key), "the masthead counts \(key) but searching it opens Archive")
        }
    }
}
