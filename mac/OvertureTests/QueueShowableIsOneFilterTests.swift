import Testing
import Foundation
import SwiftData

// #1567: "is this show showable in the Queue" was answered in two places that disagreed.
//
// LIVE-STORE-CLAIM verified=2026-07-26 measure="untriaged shows the deep-link filter and the stage lists disagreed about"
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
                         performanceDate: date, sourceListingURL: nil,
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
        StageNavigation.focusedKeys(stage: .scout, leadKeys: [], in: ps, context: .at(today, now: now))
    }

    private func opens(_ ps: [Prospect], _ key: String, reachedOut: Set<String> = []) -> Bool {
        StageNavigation.opensInQueue(key: key, in: ps, reachedOutKeys: reachedOut,
                                     context: .at(today, now: now))
    }

    private func inAStage(_ ps: [Prospect], _ key: String, reachedOut: Set<String> = []) -> Bool {
        StageNavigation.stage(containing: key, in: ps, reachedOutKeys: reachedOut,
                              context: .at(today, now: now)) != nil
    }

    // MARK: - The invariant

    // The whole rule in one test, over a store holding a show of every kind: a lead opens the Queue if
    // and only if some stage will render it. No second filter gets a say.
    @Test func aLeadOpensTheQueueExactlyWhenAStageWillRenderIt() throws {
        let ctx = try context()
        show(ctx, "near", date: "2026-08-19")                        // inside the 90 day window
        show(ctx, "far-future", date: "2027-03-01")                  // ~232 days out, past its edge
        show(ctx, "to-review", status: .drafted, date: "2027-03-01") // past the edge, and in a stage
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

    // The #1567 case, restated after #2359 rather than deleted, because the invariant it guards is
    // unchanged and the fixture's answer is not.
    //
    // The defect was never "a far out show must be reachable". It was that TWO surfaces answered one
    // question and disagreed, so a row Dan could see in his Scout list sent him to Archive. #2359 gave
    // triage the far edge the repo had been describing since #1571, and it lives in the shared predicate
    // both surfaces ask, so they still agree: the Scout list does not render a show 232 days out, and
    // searching for it opens Archive, which is now the truth about it rather than a contradiction of a
    // visible row. The show returns to both the day its date comes inside the window.
    @Test func theScoutListAndTheSearchAgreeAboutAShowPastTheWindow() throws {
        let ctx = try context()
        show(ctx, "far-future", date: "2027-03-01")

        let ps = try all(ctx)
        #expect(scoutRows(ps).isEmpty)
        #expect(!opens(ps, "far-future"))
    }

    // And the half of #1567 that #2359 leaves exactly as it was: a show INSIDE the window that the
    // Scout list renders must open in the Queue when Dan searches for it, never in Archive.
    @Test func anUntriagedShowTheScoutListRendersOpensInTheQueue() throws {
        let ctx = try context()
        // The window's LAST day, derived from the window (#3423). As a literal it was the ninetieth day
        // after the anchor, which stopped being the edge, and stopped being in the window at all, the
        // moment Dan moved it to nine weeks.
        show(ctx, "in-window", date: ScoutTestClock.day(today, plus: QueueModel.leadTimeWindowDays))

        let ps = try all(ctx)
        #expect(scoutRows(ps) == ["in-window"])
        #expect(opens(ps, "in-window"))
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

    // A show that is in a stage is reachable however far out it is. #2359 windowed TRIAGE and nothing
    // else, precisely so this stays true: a drafted show a year away is real work waiting on Dan, and a
    // row vanishing off the stage holding it would read as deletion (#1014, #901).
    @Test func aDraftedShowBeyondTheWindowStillOpensInTheQueue() throws {
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

    // LIVE-STORE-CLAIM verified=2026-07-26 measure="the masthead total against the pill beneath it, over untriaged shows"
    // The masthead's "N in the queue" now counts exactly the shows the stages hold, so it can no longer
    // read lower than the pill sitting directly beneath it. On the live store that was 452 against 589.
    //
    // #2359: with both far out shows present, so the count states the two halves of the new edge at
    // once. The untriaged one drops out (triage stops at the window); the drafted one stays, because
    // work already in flight is never hidden for its date.
    @Test func theMastheadCountsExactlyTheShowsTheStagesRender() throws {
        let ctx = try context()
        show(ctx, "near", date: "2026-08-19")
        show(ctx, "far-untriaged", date: "2027-03-01")
        show(ctx, "far-drafted", status: .drafted, date: "2027-03-01")
        show(ctx, "to-review", status: .drafted)
        show(ctx, "contacted-quiet", status: .contacted)
        show(ctx, "cut", status: .dismissed)

        let keys = StageNavigation.queueKeys(in: try all(ctx), reachedOutKeys: [],
                                             context: .at(today, now: now))

        #expect(keys == ["near", "far-drafted", "to-review"])
    }

    // Reached-out leads out of the count, as they always were: the masthead line is about work still to
    // send, and the Reached-out stage has its own pill and its own per-recipient rows.
    @Test func theMastheadCountLeavesOutTheShowsAlreadyPitched() throws {
        let ctx = try context()
        show(ctx, "near")
        show(ctx, "pitched", status: .contacted)

        let keys = StageNavigation.queueKeys(in: try all(ctx), reachedOutKeys: ["pitched"],
                                             context: .at(today, now: now))

        #expect(keys == ["near"])
    }

    // The two surfaces are one predicate, so they cannot answer differently: every show the masthead
    // counts opens the Queue when Dan searches for it.
    @Test func everyShowTheMastheadCountsOpensTheQueue() throws {
        let ctx = try context()
        show(ctx, "near", date: "2026-08-19")
        show(ctx, "far-untriaged", date: "2027-03-01")
        show(ctx, "far-drafted", status: .drafted, date: "2027-03-01")
        show(ctx, "to-review", status: .drafted)
        show(ctx, "contacted-quiet", status: .contacted)
        show(ctx, "cut", status: .dismissed)

        let ps = try all(ctx)
        for key in StageNavigation.queueKeys(in: ps, reachedOutKeys: [], context: .at(today, now: now)) {
            #expect(opens(ps, key), "the masthead counts \(key) but searching it opens Archive")
        }
    }
}
