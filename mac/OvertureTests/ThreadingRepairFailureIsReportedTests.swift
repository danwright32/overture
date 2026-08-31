import Testing
import Foundation
import SwiftData

// #2679: `GmailThreadingRepair` (#2649) reports four outcomes on purpose and its only caller discarded
// all of them. `ReconcileScheduler` line 125 was a bare `await GmailThreadingRepair().repair(in: context)`.
//
// `saveFailed` is the one that matters. The repair rewrites a stored Message-ID, and when the save then
// fails nothing persisted and nothing said so, so the next follow-up still ships a dangling reference
// while the pass looks like it ran: success over a write that did not commit (L12), inside a background
// job whose failure reached nothing that could report it (L13).
//
// The precedent followed here is two lines above it in the same function: `GmailReplyChecker.checkReplies`
// returns whether its save failed, the tick folds that into `ReconcileSummary.saveFailed`, and RootView
// renders it. One flag, not a second path.
@MainActor
@Suite("A threading repair that cannot save says so (#2679)")
struct ThreadingRepairFailureIsReportedTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func tick(_ ctx: ModelContext,
                      repair: GmailThreadingRepair.Outcome?) async -> ReconcileSummary {
        await ReconcileScheduler(context: ctx, replyRunAlive: { _ in false }).runSafeReconcilesOnce(
            // #3272: UUID scoped, and no `?? .standard` fallback. That fallback would have handed the
            // REAL shared defaults to a test, by a spelling the guard forbidding `UserDefaults.standard`
            // cannot see, and it is unreachable in practice, so it was a silent hole rather than safety.
            defaults: UserDefaults(suiteName: "overture.tests.2679-\(UUID().uuidString)")!,
            repairThreading: { _ in repair })
    }

    // The defect, stated as the tick's own answer. A repair that changed rows and could not write them
    // must reach the flag Dan's status line reads, not be dropped on the floor.
    @Test func aRepairThatCannotSaveReachesTheTicksSummary() async throws {
        var failed = GmailThreadingRepair.Outcome()
        failed.repaired = 2
        failed.saveFailed = true

        let summary = await tick(try context(), repair: failed)

        #expect(summary.saveFailed, "the repair's failed save was discarded")
        // And it reaches Dan in words, not only as a flag: the same sentence the reply checker's and the
        // retirement's failures already produce, which is why they share the field.
        #expect(summary.message.contains("couldn't save"))
    }

    // The no-op edge, and the one that decides whether this is safe to ship. Every quiet tick runs this
    // pass, and #499's alert fires on `saveFailed` alone with no new leads needed, so a clean repair that
    // read as a failure would wake Dan every few minutes.
    @Test func aCleanRepairDoesNotReportAFailure() async throws {
        var clean = GmailThreadingRepair.Outcome()
        clean.repaired = 3

        #expect(await tick(try context(), repair: clean).saveFailed == false)
    }

    // nil is Gmail not being connected, which is not a pass that ran and failed. Nothing was attempted,
    // so there is nothing to report, and the distinction is the whole reason `repair` returns an optional
    // rather than an empty Outcome (L11: a message may claim only what its check actually measured).
    @Test func gmailBeingDisconnectedIsNotASaveFailure() async throws {
        #expect(await tick(try context(), repair: nil).saveFailed == false)
    }

    // A pass that found nothing to repair is also not a failure. Distinct from the case above because
    // this one DID run: Gmail was reachable, and every live conversation already held a real id.
    @Test func aPassWithNothingToRepairIsNotAFailure() async throws {
        #expect(await tick(try context(), repair: GmailThreadingRepair.Outcome()).saveFailed == false)
    }

    // The two counts that deliberately get no surface of their own, asserted so the decision is on the
    // record rather than implied by their absence. A refusal already marks its rows `threadingDegraded`,
    // which the `.sendThreadingDegraded` focus reads, and an unreadable thread means Gmail could not be
    // read this tick, which the next free tick retries and which #1912 owns.
    @Test func refusalsAndUnreadableThreadsDoNotWakeDan() async throws {
        var busy = GmailThreadingRepair.Outcome()
        busy.refused = 4
        busy.unreadable = 7

        #expect(await tick(try context(), repair: busy).saveFailed == false)
    }
}
