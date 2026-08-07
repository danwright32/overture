import Testing
import Foundation
import SwiftData

// #418 A0, "right over fast": prove the thread-down repair against a COPY of Dan's real, irreplaceable
// live store (~/Library/Application Support/Overture/Overture.store, ZPROSPECT), not just an
// in-memory fixture. Gated on the live store existing, so it reports as a SKIP (not a silent pass) on
// CI and other machines (#416).
@Suite("Recipient backfill — live store")
struct RecipientBackfillLiveStoreTests {
    // The Release store explicitly (isDebugBuild: false): the test bundle is always a Debug build,
    // but we want the resident copy's store, not the isolated Overture-Debug one.
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    // SUP-042: both tests below are gated on the live store existing, so a run on a machine without
    // one (CI, another Mac) must show as a visible SKIP, not a silent pass that asserted nothing.
    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    // Copy the store and its SQLite sidecars (-wal, -shm) to a fresh scratch dir so the consistent
    // database state is preserved. The .lock flock file is deliberately not copied.
    // #1672: through the ONE shared clone. Copying the .store and its sidecars one file at a time
    // races a live writer, and a clone whose -wal does not match the .store beside it makes
    // whatever this suite concludes a statement about a torn copy rather than about Dan's data.
    // LiveStoreClone takes it through SQLite's online backup, which folds the WAL in as it goes,
    // so the newest writes are still there and there is no sidecar left to mismatch.
    private func copyLiveStore(to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return clone
    }

    // Open under the CURRENT app schema (Prospect + the Recipient @Model, #409). Opening a store
    // created under the old Prospect-only schema this way is exactly the additive entity+relationship
    // migration Dan's real store will undergo on first launch of the promoted build — proving it here
    // on a COPY is the Phase C gate.
    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    // #418 A0 — prove the #416 thread-down repair is safe and idempotent against a COPY of Dan's real,
    // irreplaceable store BEFORE it runs at launch. Robust to the exact row counts (which can't be
    // queried while the resident app holds the live store): asserts invariants, not fixed numbers.
    // #1006: real, disk-backed ModelContainer work runs between an acquire()/release() pair so it
    // never overlaps another suite's, in the whole process.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func threadDownRepairOnACopyOfTheLiveStoreIsSafeAndIdempotent() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-threaddown-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let container = try openContainer(at: storeCopy)
            let ctx = ModelContext(container)

            let before = try ctx.fetch(FetchDescriptor<Prospect>())
            let prospectCount = before.count
            let recipientCountBefore = before.reduce(0) { $0 + $1.recipients.count }
            // Record which recipients already had a thread, so we can prove the repair only ADDS threads
            // to legacy act rows and never rewrites an existing one or touches an unrelated row.
            let threadedIdsBefore = Set(before.flatMap { $0.recipients.filter { $0.gmailThreadId != nil }.map(\.id) })

            let repaired = RecipientBackfill.repairThreadDown(in: ctx)
            try ctx.save()

            let after = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(after.count == prospectCount)                                   // no prospect added/lost
            #expect(after.reduce(0) { $0 + $1.recipients.count } == recipientCountBefore)  // no recipient added/lost
            for p in after {
                for r in p.recipients {
                    // Any row that NEWLY gained a thread must be a legacy act on a contacted show, now .sent.
                    if r.gmailThreadId != nil && !threadedIdsBefore.contains(r.id) {
                        #expect(r.provenance == .act)
                        #expect(r.sendState == .sent)
                        #expect(p.gmailThreadId != nil && p.sentAt != nil)
                    }
                    // A recipient whose show has no lead thread can never have been given one.
                    if p.gmailThreadId == nil { #expect(r.gmailThreadId == nil || threadedIdsBefore.contains(r.id)) }
                }
            }

            // Idempotent across a relaunch: reopen and re-run; nothing left to repair.
            let reopened = try openContainer(at: storeCopy)
            let reCtx = ModelContext(reopened)
            #expect(RecipientBackfill.repairThreadDown(in: reCtx) == 0)
            _ = repaired   // count is data-dependent (0..N); the invariants above are what matter
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
