import Testing
import Foundation
import SwiftData

// #1566: the went-by sweep only ever ran at launch, and Dan leaves Overture open for days.
//
// #864 put the sweep in LaunchMigrations, which was enough while the line it applied fell on a run's
// CLOSING night: a show has to be over before it can rot, and the odds of one ending during a session
// were low enough to live with. #1540 moved that line to the OPENING night, which every run in the
// queue crosses on its own opening day, so the rows this takes are now created by the calendar turning
// over rather than by a show finishing. Left at launch only, a run that opens while the app is up sits
// in triage offering work Dan has said he will not do, until he next quits and relaunches.
//
// So it rides the reconcile tick, which already owns exactly this shape of periodic re-judgement: the
// booking pass and the conflict re-check (#923) both run there, on launch, the 30-minute timer, and
// every Downbeat export change. The launch call stays: the tick's first pass is asynchronous, so
// without it a stale row can paint before the sweep runs.
@MainActor
@Suite("The went-by sweep rides the reconcile tick, not only launch (#1566)")
struct WentByRetirementOnTheTickTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    // Dated far enough out that no live export or real clock can reach it; the tick's own `now` decides.
    private let openingNight = "2096-10-01"
    private let before = Date(timeIntervalSince1970: 3_999_000_000)   // 2096-09-25, before it opens
    private let after = Date(timeIntervalSince1970: 4_000_000_000)    // 2096-10-02, after it opened

    @discardableResult
    private func untriaged(_ ctx: ModelContext, _ key: String, date: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        return p
    }

    // The gap the issue names: the app was already open when the show's opening night arrived.
    @Test func aShowThatOpensBetweenTicksIsRetiredWithoutARelaunch() throws {
        let ctx = try context()
        let show = untriaged(ctx, "opens-during-the-session", date: openingNight)
        let scheduler = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })

        // An earlier tick, while it was still ahead: not Overture's to take.
        #expect(scheduler.retireShowsThatOpened(now: before).count == 0)
        #expect(show.status == .new)

        // The calendar turns over with the app still running.
        #expect(scheduler.retireShowsThatOpened(now: after).count == 1)
        #expect(show.status == .dismissed)
        #expect(show.showOutcome == .wentBy)
    }

    // The tick judges against the clock it was handed, never Date() reached for inside. Without this the
    // pass would be untestable and would quietly disagree with the rest of the tick, which is threaded
    // `now` precisely so a test can drive it.
    @Test func theTickJudgesAgainstItsOwnClock() throws {
        let ctx = try context()
        let show = untriaged(ctx, "future", date: openingNight)

        _ = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false }).retireShowsThatOpened(now: before)

        #expect(show.status == .new, "a tick dated before the opening must not retire it")
    }

    // The failure/no-op edge: a tick with nothing to retire must report no save failure, or every quiet
    // tick would wake Dan with "reconcile couldn't save its results" (#499's alert fires on saveFailed
    // alone, with no new leads needed).
    @Test func aTickWithNothingToRetireReportsNoSaveFailure() throws {
        let ctx = try context()
        untriaged(ctx, "future", date: openingNight)
        untriaged(ctx, "undated", date: nil)

        let result = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false }).retireShowsThatOpened(now: before)

        #expect(result.count == 0)
        #expect(result.saveFailed == false)
    }

    // The failure path that matters: the store refuses the write. #499 is exactly this bug one pass over,
    // a save swallowed by a bare `try?`, so a retirement that never reached disk would report success,
    // vanish the row from this session, and have it back at the next launch with no signal anywhere.
    // Reported through the tick summary, which wakes Dan on saveFailed alone even with no new leads.
    @Test func aRetirementThatCannotBeSavedIsReportedNotSwallowed() throws {
        struct StoreRefused: Error {}
        let ctx = try context()
        let show = untriaged(ctx, "opened", date: openingNight)

        let result = ReconcileScheduler(context: ctx, replyRunAlive: { _ in false })
            .retireShowsThatOpened(now: after, save: { throw StoreRefused() })

        #expect(result.count == 1, "it still says what it did, so the count is not lost with the save")
        #expect(result.saveFailed, "a failed save must surface, never read as a clean tick")
        #expect(ReconcileSummary(omniFocusChanged: 0, saveFailed: result.saveFailed).message
                    .contains("couldn't save"), "and reach Dan in words, not just as a flag")
        #expect(show.showOutcome == .wentBy, "the in-memory cut stands; only its persistence failed")
    }

    // A guard and its wiring are two claims. The three above prove the pass works; this proves the tick
    // actually calls it, by running the real tick rather than the method it is supposed to reach.
    @Test func therealTickRetiresAnOpenedShow() async throws {
        let ctx = try context()
        // A UUID key so this can never collide with a real booking in the live export the tick reads.
        let show = untriaged(ctx, "ticked-\(UUID().uuidString)", date: openingNight)
        try ctx.save()

        _ = await ReconcileScheduler(context: ctx, replyRunAlive: { _ in false }).runSafeReconcilesOnce(now: after)

        #expect(show.status == .dismissed)
        #expect(show.showOutcome == .wentBy)
    }
}
