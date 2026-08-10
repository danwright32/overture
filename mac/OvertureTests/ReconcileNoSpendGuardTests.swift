import Testing
import Foundation
import SwiftData

// #1098 (from the #982 sweep): ReconcileScheduler is documented to run ONLY the safe, free, deterministic
// reconciles and to NEVER trigger a Prep run, a reply-classify run, or a scout, the #237 unattended-AI
// safety guarantee. It is the highest-risk load-bearing claim the sweep found with zero test coverage:
// a future edit could quietly wire a paid `claude -p` run into a windowless timer tick and start spending
// Dan's Max-plan capacity while he is away, and everything would still compile and every other test would
// still pass.
//
// The three paid runs can be initiated in exactly one way each: PrepQueueService.startPrep,
// ReplyClassifyService.startClassify, and ScoutExtractService.startExtract, all of which funnel through
// DetachedRunner.launch. A reconcile tick can therefore only spend by NAMING one of those symbols. The
// source guards below fail the instant any of them appears in the reconcile owner (matching this project's
// convention for a wiring fact with no behavioral surface, e.g. AutoScoutSpendGuardTests), and the
// behavioral test runs a real tick and proves it leaves the paid work untouched.
@MainActor
@Suite("Reconcile tick never initiates a paid AI run (#1098, #237)")
struct ReconcileNoSpendGuardTests {
    // The ONLY entry points that launch a detached `claude -p` run. Naming any of them from the reconcile
    // owner is the only way a tick could spend, so this is the whole surface the guard has to cover.
    private static let paidRunLaunchers = [
        "PrepQueueService",     // the Prep run
        "ReplyClassifyService", // the reply-classify run
        "ScoutExtractService",  // the scout
        "DetachedRunner",       // the shared launch mechanism all three go through
    ]

    private var reconcileScheduler: String {
        SourceGuardHelper.source("Overture/App/ReconcileScheduler.swift")
    }

    // The whole reconcile owner (start, runNow, the tick, and every helper the tick reaches through this
    // file) must not so much as name a paid-run launcher. This is the primary enforcement: it catches a
    // future edit adding a spend call anywhere in the scheduler, not just inside the tick function.
    @Test func theReconcileOwnerNeverNamesAPaidRunLauncher() {
        #expect(!reconcileScheduler.isEmpty)
        for launcher in Self.paidRunLaunchers {
            #expect(!reconcileScheduler.contains(launcher),
                    "ReconcileScheduler references \(launcher): a windowless reconcile tick must never be able to initiate a Prep, reply-classify, or scout run (#237/#1098).")
        }
    }

    // Scoped to the tick itself, so a failure points straight at runSafeReconcilesOnce, the one method the
    // timer and the export-change watcher actually call while Dan is away.
    @Test func theTickBodyNamesNoPaidRunLauncher() throws {
        let body = try SourceGuard.functionBody(named: "runSafeReconcilesOnce", in: reconcileScheduler)
        for launcher in Self.paidRunLaunchers {
            #expect(!body.contains(launcher),
                    "runSafeReconcilesOnce references \(launcher): the tick must stay free of any paid AI run (#237/#1098).")
        }
    }

    // Behavioral: run a real tick against a store that is simultaneously eligible for a Prep run (a kept,
    // undrafted prospect) and carries a fresh reply awaiting classification, then prove neither paid step
    // happened. A Prep run is what turns a kept prospect into a drafted one; a reply-classify run is what
    // gives a reply a conversationState. The tick does the free work (booking detection, conflict re-judge,
    // read-only Gmail reply detection, OmniFocus push) and leaves both paid outputs untouched. The
    // assertions are invariants of the free tick, so they hold regardless of the host's Gmail/OmniFocus/
    // export state: the free reconciles simply have no path that drafts or classifies.
    @Test func aRealTickLeavesTheKeptProspectUndraftedAndTheReplyUnclassified() async throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, DayOff.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))

        // A kept (.queued), never-drafted prospect: eligible for a Prep run. A UUID-derived key/name so it
        // can never collide with a real booking in Dan's live export the tick reads.
        let key = "no-spend-\(UUID().uuidString)"
        let p = Prospect(naturalKey: key, groupName: "No Spend Chorus \(UUID().uuidString)",
                         discipline: "choral", venue: "V", performanceDate: "2099-01-01",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        // A sent recipient that replied but has no conversationState yet: awaiting a reply-classify run.
        let r = Recipient(id: "c@e.com", email: "c@e.com", provenance: .act)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailThreadId = "t1"
        r.replied = true
        p.setRecipients([r])
        ctx.insert(p)
        try ctx.save()

        #expect(PrepQueueBuilder.needsPrepEligible(p))   // precondition: it WOULD be picked up by a Prep run
        #expect(r.intentHint == nil)                     // precondition: the reply is unread by the model

        let scheduler = ReconcileScheduler(context: ctx)
        _ = await scheduler.runSafeReconcilesOnce(now: Date(timeIntervalSince1970: 4_000_000_000))

        // The tick drafted nothing: the prospect is still kept-and-undrafted, still awaiting a Prep run.
        #expect(p.status == .queued)
        #expect(!p.hasDraft)
        #expect(PrepQueueBuilder.needsPrepEligible(p))
        // The tick classified nothing: the reply still carries no AI-assigned hint.
        #expect(r.intentHint == nil)
    }
}
