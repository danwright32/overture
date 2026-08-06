import Testing
import Foundation
import SwiftData

// #2190: prove the backfill against a COPY of Dan's real store before it is ever allowed to run at launch
// on the real one. The pass writes to every recipient it selects, so an in-memory fixture proves only that
// it does what I imagined the store looks like.
//
// Asserts INVARIANTS, never a row count. The count is 2 today and becomes 0 the moment the fix ships and
// repairs them, so a pinned number would go red BECAUSE the fix worked, and the test would then be
// deleted or loosened by whoever hit it, which is how a guard dies. Every assertion below stays true for
// as long as the pass exists, on a store that has been repaired and on one that never needed it.
@Suite("Answered-reply backfill (#2190), live store")
struct AnsweredReplyBackfillLiveStoreTests {
    // The RELEASE store: the test bundle is always a Debug build, and it is Dan's resident copy that
    // carries the damage.
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    // Gated on the store existing so another Mac (or CI) shows a visible SKIP rather than a silent pass
    // that asserted nothing.
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func copyLiveStore(to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("default.store")
        // The sidecars matter: the most recent writes live in the write-ahead log, so a copy of the main
        // file alone is a stale store and would under-report what the pass touches.
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: Self.liveStoreURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
        }
        return dest
    }

    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    // #1006: real, disk-backed ModelContainer work runs between an acquire()/release() pair so it never
    // overlaps another suite's. Released inline on BOTH exit paths, never from a `defer` that hands the
    // release to an unstructured Task: that defers it to an unpredictable moment, lets this critical
    // section overlap another suite's, and reaches the SwiftData store-coordinator crash this lock exists
    // to prevent. Measured 2026-08-06: with the Task form, the run died partway and reported a different
    // innocent test as "failing" on each attempt, with 600 to 1,500 tests never executed.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theBackfillOnACopyOfTheLiveStoreOnlyEverStampsAProvenAnswer() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            try await checkTheBackfillOnACopy()
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    private func checkTheBackfillOnACopy() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("overture-answeredreply-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }

        let copy = try copyLiveStore(to: scratch)
        let ctx = ModelContext(try openContainer(at: copy))

        // What was asking before the pass, so the check below compares against a measured before-state
        // rather than against the pass's own opinion of what it did (L70).
        let before = Set((try ctx.fetch(FetchDescriptor<Prospect>()))
            .flatMap(\.recipients).filter(\.hasUnhandledReply).map(\.id))

        let changed = AnsweredReplyBackfill.run(in: ctx)

        let all = (try ctx.fetch(FetchDescriptor<Prospect>())).flatMap(\.recipients)
        let stamped = all.filter { before.contains($0.id) && !$0.hasUnhandledReply }

        // 1. It reports exactly what it did. A pass whose return value and effect disagree can never be
        // trusted to say what it touched on the store nobody can inspect afterwards.
        #expect(stamped.count == changed,
                "the pass returned \(changed) but \(stamped.count) rows stopped asking")

        // 2. Every row it stamped had an answer PROVABLY sent on its own conversation, after the reply
        // arrived. This is the whole safety property: nothing is cleared on the strength of an empty field.
        for r in stamped {
            let prospect = try #require(all.first { $0.id == r.id }?.prospect)
            let answers = SendGroup.peers(of: r, in: prospect)
                .filter { $0.id == r.id || $0.lastReplyId == r.lastReplyId }
                .compactMap(\.replySentAt)
            let latest = try #require(answers.max(),
                                      "stamped \(r.id) with no answer anywhere on its conversation")
            let arrived = try #require(r.replyArrivedAt, "stamped \(r.id) with no reply arrival time")
            #expect(latest > arrived, "stamped \(r.id) with an answer older than the reply it answers")
            #expect(r.replyHandledAt == latest, "stamped \(r.id) with a date that is not when he answered")
        }

        // 3. Nothing that was NOT asking changed. The pass may only ever move a row out of the waiting
        // state, never into it.
        let nowAsking = Set(all.filter(\.hasUnhandledReply).map(\.id))
        #expect(nowAsking.isSubset(of: before), "the pass put a row INTO the waiting state")

        // 4. It runs at every launch, so a second pass must be a no-op on the store it just repaired.
        #expect(AnsweredReplyBackfill.run(in: ctx) == 0, "a second run on the same store changed rows")

        // Reported rather than asserted: the number is 2 today and 0 once this ships, and both are correct.
        print("#2190 live-store dry run: \(changed) row(s) stamped, \(before.count) were asking beforehand")
        for r in stamped { print("  stamped \(r.id) at \(String(describing: r.replyHandledAt))") }
    }
}
