import Testing
import Foundation
import SwiftData
@testable import Overture

// Phase 1 (#391), "right over fast": prove the recipients backfill against a COPY of Dan's real,
// irreplaceable live store (~/Library/Application Support/default.store, ZPROSPECT) — not just an
// in-memory fixture. Opening the copy under the current schema also exercises the additive,
// defaulted-attribute migration the whole storage decision rests on. Gated on the live store
// existing, so it is a silent no-op on CI and other machines.
@Suite("Recipient backfill — live store")
struct RecipientBackfillLiveStoreTests {
    // The Release data directory explicitly (isDebugBuild: false): the test bundle is always a Debug
    // build, but we want the resident copy's store, not the isolated Overture-Debug one.
    private var liveStoreURL: URL {
        StoreLocation.dataDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent("default.store")
    }

    // Copy the store and its SQLite sidecars (-wal, -shm) to a fresh scratch dir so the consistent
    // database state is preserved. The .lock flock file is deliberately not copied.
    private func copyLiveStore(to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: liveStoreURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
        }
        return dest
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

    @Test func backfillsEveryContactedProspectInACopyOfTheLiveStore() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: liveStoreURL.path) else { return }  // no live store here: skip

        let scratch = fm.temporaryDirectory
            .appendingPathComponent("overture-backfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let storeCopy = try copyLiveStore(to: scratch)

        // First open: applies the additive recipientsRaw migration, then backfill.
        let container = try openContainer(at: storeCopy)
        let context = ModelContext(container)
        let all = try context.fetch(FetchDescriptor<Prospect>())

        let seeded = RecipientBackfill.run(in: context)
        try context.save()

        // Every prospect with a real contact email now has exactly one act recipient mirroring it;
        // a scout-only prospect (no email) has none.
        var expectedSeed = 0
        for p in all {
            if let email = p.contactEmail, !email.isEmpty {
                expectedSeed += 1
                #expect(p.recipients.count == 1)
                let r = p.recipients.first
                #expect(r?.provenance == .act)
                #expect(r?.email == email)
                #expect(r?.sendState == (p.sentAt != nil ? .sent : .pending))
            } else {
                #expect(p.recipients.isEmpty)
            }
        }
        #expect(seeded == expectedSeed)

        // Idempotent across a relaunch: reopen the saved copy in a fresh container and re-run.
        let reopened = try openContainer(at: storeCopy)
        let reContext = ModelContext(reopened)
        #expect(RecipientBackfill.run(in: reContext) == 0)
        let reAll = try reContext.fetch(FetchDescriptor<Prospect>())
        #expect(reAll.filter { !$0.recipients.isEmpty }.count == expectedSeed)
    }
}
