import Testing
import Foundation
import SwiftData

// #3657 (milestone #80, Phase 7): an instrument that can actually SEE the Follow-ups surface, and the
// reading it takes.
//
// WHY A NEW INSTRUMENT, which is the whole of CORRECTION C5. The plan said to measure this with the
// Phase 0 instruments. Those are `QueueRenderPass.WorkTally`'s counters, and they are bound around
// building a queue CARD: `recordQueueItem` in `QueueItem.init`, `recordSendGroupBuild` in
// `SendGroup.CardGroups.init`, `recordDraftLintRun` in the lint, `recordRecipientReach` in
// `Prospect.reachabilityResultFromRecipients`. `FollowUpsView` reaches none of them, so a reading taken
// with them comes back at zero BY CONSTRUCTION, and a zero from an instrument nothing calls is
// UNMEASURED rather than cheap (L90, L98, L248).
//
// Verified 2026-09-08, and the reason is sharper than the issue's: `DueWork.swift` really does contain
// no `QueueItem(`, no `DraftCheck` and no `Corpus`, but it is NOT true that it never touches `SendGroup`.
// `FollowUp.dueRecipients` calls `SendGroup.oneRowPerGroup` once per prospect (`FollowUp.swift:202`).
// That is the CHEAP half of `SendGroup`, a sort and a dedupe; only `CardGroups.init(of:)`
// (`SendGroup.swift:107`) records `recordSendGroupBuild()`. So the counter genuinely reads zero here,
// and it reads zero for a reason worth writing down rather than because the file happens not to name the
// type: checking the text of one file would have got the right answer for the wrong reason (L135).
//
// WHAT THIS SURFACE ACTUALLY COSTS, which no counter here can express: `DueWork.rows` is a pure function
// over the WHOLE prospect list, and it is a COMPUTED PROPERTY on the view (`FollowUpsView.swift:69`), so
// every body evaluation re-runs all four of its passes over every prospect and every recipient. A
// computed property reads as a free field access at its call site and nothing there says what it costs
// (L383). So the instrument is a stopwatch over the live corpus, which is the only thing that can see it.
@Suite("What one Follow-ups derivation costs (#3657)")
struct FollowUpsCostTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func liveProspects(in dir: URL) throws -> [Prospect] {
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self])
        let ctx = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)]))
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    // THE POSITIVE CONTROL, and it runs on every push rather than behind the opt-in.
    //
    // A stopwatch over a derivation that returns nothing measures the cost of returning nothing, and its
    // small number reads exactly like a cheap surface (L171: a control satisfiable by the wrong data
    // cannot detect a dead instrument). This proves the derivation does real work on a corpus that
    // CONTAINS work, so the reading below is a reading of something.
    @Test func theDerivationReallyProducesRowsWhenThereIsWorkToDo() throws {
        let ctx = ModelContext(try ModelContainer(
            for: Schema([Prospect.self, Recipient.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let now = Date()
        // DERIVED from `now`, never a literal. A fixture whose meaning is its relationship to the clock
        // must pin both ends, or real time walks it into a different case and the test goes on asserting
        // about a case nobody chose (L130). A run still ahead is what `FollowUp.hasPerformed` requires.
        let aheadOfUs = EasternDate.today(now.addingTimeInterval(60 * 60 * 24 * 60))
        let p = Prospect(naturalKey: "control-show", groupName: "A Control Show", discipline: "choral",
                         venue: "A Control Room", performanceDate: aheadOfUs, sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "someone@example.invalid", email: "someone@example.invalid",
                          name: "A Contact", provenance: .act)
        // Every clause `FollowUp.isAwaitingNudge` and `Recipient.isAwaitingFollowUp` ask, set explicitly
        // rather than inherited from a default, so this control cannot go quiet because a default moved.
        r.sendState = .sent
        r.outreachChannel = .email
        r.replied = false
        r.bounced = false
        // Pitched well past the nudge gap and never followed up, which is what `FollowUp.isDue` asks.
        r.sentAt = now.addingTimeInterval(-60 * 60 * 24 * 30)
        p.recipients.append(r)
        try ctx.save()

        let rows = DueWork.rows(prospects: [p], now: now, replyRunAlive: false)
        #expect(!rows.silent.isEmpty,
                Comment(rawValue: "a contact pitched 30 days ago and never chased produced no silent "
                        + "follow-up, so this instrument is timing a derivation that returns nothing and "
                        + "its number would read as a cheap surface (L171)."))
    }

    // THE READING. Opt in, because it clones the live store and runs a stopwatch, neither of which
    // belongs in the suite that runs before every push.
    //
    //   TEST_RUNNER_MEASURE_FOLLOW_UPS=1 mac/scripts/run-tests-locked.sh \
    //     -only-testing:OvertureTests/FollowUpsCostTests
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func measureOneFollowUpsDerivation() async throws {
        guard ProcessInfo.processInfo.environment["MEASURE_FOLLOW_UPS"] != nil else {
            // Never silently skipped: an instrument that says nothing is indistinguishable from one that
            // ran and found the surface cheap (L98).
            print("follow-ups-cost: not measured. Set TEST_RUNNER_MEASURE_FOLLOW_UPS=1 to run it.")
            return
        }
        await RealStoreTestLock.shared.acquire()   // #2198: released inline on both paths, never a Task
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("follow-ups-cost-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let prospects = try liveProspects(in: dir)
            let recipients = prospects.reduce(0) { $0 + $1.recipients.count }
            let now = Date()

            // Warmed first, because the first pass also faults every recipient in from SwiftData and that
            // is a cost of the FETCH rather than of the derivation the view re-runs on every body
            // evaluation. What this reading is about is the repeat.
            _ = DueWork.rows(prospects: prospects, now: now, replyRunAlive: false)

            let rounds = 10
            let started = Date()
            var lastRows = DueWork.Rows(afterTheShow: [], silent: [], stalledReplyDrafts: [],
                                        conversationsToConfirm: [])
            for _ in 0..<rounds {
                lastRows = DueWork.rows(prospects: prospects, now: now, replyRunAlive: false)
            }
            let perRun = Date().timeIntervalSince(started) / Double(rounds) * 1000

            print(String(format: "follow-ups-cost: one DueWork.rows over %d prospects and %d "
                         + "recipients took %.1f ms (mean of %d, after a warm pass). It produced %d "
                         + "after-the-show, %d silent, %d stalled reply drafts and %d conversations to "
                         + "confirm. This is a COMPUTED property on FollowUpsView, so every body "
                         + "evaluation pays it in full.",
                         prospects.count, recipients, perRun, rounds,
                         lastRows.afterTheShow.count, lastRows.silent.count,
                         lastRows.stalledReplyDrafts.count, lastRows.conversationsToConfirm.count))

            #expect(prospects.count > 0, "the clone holds no prospects, so nothing here was measured")

            // THE BUSY DAY, and it is not optional. The reading above is taken on Dan's real store,
            // where nothing is currently due, and `FollowUp.dueRecipients` calls
            // `SendGroup.oneRowPerGroup` only on the contacts that ARE due: with none due it is handed
            // an empty array every time. So that number is the cost of the SHORT CIRCUIT, and a code
            // path that switches on its input always takes the cheap branch under test while the branch
            // that ships is the one never exercised (L101, L102). Quoting it alone would be a
            // measurement of the easy case offered as permission (L246).
            //
            // Same corpus, same recipients, one clock. Only `now` moves, to just past the nudge gap
            // after the LATEST pitch in the store, which is the only single instant at which every
            // pitched contact is past its gap at once. Derived from the data rather than chosen, so it
            // cannot drift into meaning something else as the store grows (L130, L401).
            //
            // The EARLIEST pitch was tried first and produced nothing, which the guard below caught: at
            // that clock every other contact's own pitch is still in the future, so one row could be due
            // at most. That is the instrument being checked before it was believed.
            let busyNow = prospects.flatMap { $0.recipients.compactMap(\.sentAt) }
                .max().map { $0.addingTimeInterval(60 * 60 * 24 * 7) } ?? now
            _ = DueWork.rows(prospects: prospects, now: busyNow, replyRunAlive: false)
            let busyStarted = Date()
            var busyRows = lastRows
            for _ in 0..<rounds {
                busyRows = DueWork.rows(prospects: prospects, now: busyNow, replyRunAlive: false)
            }
            let busyPerRun = Date().timeIntervalSince(busyStarted) / Double(rounds) * 1000
            let busyTotal = busyRows.afterTheShow.count + busyRows.silent.count
                + busyRows.stalledReplyDrafts.count + busyRows.conversationsToConfirm.count
            print(String(format: """
                follow-ups-cost (busy): the same corpus at a clock where work IS due took %.1f ms                 (mean of %d) and produced %d rows: %d after-the-show, %d silent, %d stalled reply                 drafts, %d to confirm. This is the bracket the reading above cannot give, because with                 nothing due SendGroup.oneRowPerGroup is handed an empty array every time.
                """, busyPerRun, rounds, busyTotal,
                busyRows.afterTheShow.count, busyRows.silent.count,
                busyRows.stalledReplyDrafts.count, busyRows.conversationsToConfirm.count))
            #expect(busyTotal > 0,
                    Comment(rawValue: "the busy reading produced no rows either, so it is a second "
                            + "measurement of the same short circuit rather than a bracket (L171)."))

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
