import Testing
import Foundation
import SwiftData

// #1693: prove the recheck against a COPY of Dan's real store before it is ever allowed to run against
// the real one. The in-memory tests next door prove the rule; this proves the rule meets his 700-odd
// actual rows and clears the flags it should while leaving the ones he still needs to answer.
//
// Deliberately asserts invariants rather than fixed counts (the store changes daily), except for the one
// record this issue is about, which must be gone from every row. Gated on the live store existing, so a
// machine without one reports a visible SKIP rather than a silent pass.
@Suite("Possible-match recheck, live store (#1693)")
struct PossibleMatchRecheckLiveStoreTests {
    // The Release store and the Release handoff directory explicitly: the test bundle is a Debug build,
    // and its own directories hold no Downbeat export at all, which is exactly what made the first
    // version of the launch-wiring test assert nothing.
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var releaseHandoff: URL {
        StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func copyLiveStore(to dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("Overture.store")
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

    // The same two files the real pass reads, but named off the RELEASE directory.
    private func realInputs(_ prospects: [Prospect]) -> PossibleMatchRecheck.Inputs? {
        let export = DownbeatBridge.loadWithHealth(
            from: Self.releaseHandoff.appendingPathComponent("downbeat-export.json"), now: Date())
        switch export.health {
        case .missing, .unreadable: return nil
        case .ok, .stale: break
        }
        let history = LocalHistory.forMatchingWithHealth(
            existing: prospects,
            importedFrom: Self.releaseHandoff.appendingPathComponent("overture-history.json"))
        if history.unreadable { return nil }
        return PossibleMatchRecheck.Inputs(clients: export.clients, history: history.records)
    }

    // The record the issue is about: an act Dan has never worked with, reached only because the colon
    // strip deleted its name and left the hall's brand behind to score on.
    private let wrongRecord = "Carnegie Hall Citywide: Ivalas Quartet"

    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func onACopyOfTheLiveStoreItClearsTheWrongFlagsAndKeepsTheRealOnes() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1693-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let before = try ctx.fetch(FetchDescriptor<Prospect>())
            let unflaggedKeysBefore = Set(before.filter { ($0.possibleMatchName ?? "").isEmpty }.map(\.naturalKey))
            let relationshipsBefore = Dictionary(before.map { ($0.naturalKey, $0.priorRelationship) },
                                                 uniquingKeysWith: { a, _ in a })
            // Snapshot every flag as a VALUE before the pass mutates the rows in place, so the
            // honest-reporting check below compares strings rather than re-reading the same objects.
            let flagsBefore = Dictionary(before.map { ($0.naturalKey, $0.possibleMatchName ?? "") },
                                         uniquingKeysWith: { a, _ in a })
            // The pass reads two real files, and if either is missing it correctly declines to judge and
            // changes nothing. That is indistinguishable from a converged store unless it is asserted, so
            // this is what proves the run below actually happened against real inputs rather than
            // no-opping its way through every remaining assertion.
            #expect(realInputs(before) != nil,
                    "the Downbeat export and history this pass reads are both present")

            let changed = PossibleMatchRecheck.run(in: ctx, loadInputs: realInputs)
            try ctx.save()

            let after = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(after.count == before.count, "no row added or lost")
            // LIVE-STORE-CLAIM verified=2026-07-29 measure="rows carrying a possible-match flag before this pass, how many it changed, and how many survived"
            // Measured 2026-07-28, when this was written: 21 flagged, 18 cleared, 3 left. Re-measured
            // 2026-07-29: 1 flagged and nothing left to clear, because this pass runs on launch and has
            // since cleared them all on Dan's own store.
            //
            // So "it changed something" is no longer assertable, and an earlier version asserting it made
            // the fix's own success show up as a red suite. What replaces it is stronger anyway: the count
            // the pass REPORTS must equal the number of flags that actually moved. That holds on a
            // converged store (nothing moved, nothing reported) and catches both directions of the lie,
            // a pass reporting work it did not do and one doing work it does not report.
            let actuallyMoved = after.filter { ($0.possibleMatchName ?? "") != flagsBefore[$0.naturalKey] }
            #expect(changed == actuallyMoved.count,
                    "reported \(changed) changed, \(actuallyMoved.count) flags actually moved")

            // The defect itself, gone from every row.
            #expect(after.allSatisfy { $0.possibleMatchName != wrongRecord })

            // It never hands out a flag: a row that had none still has none.
            for p in after where unflaggedKeysBefore.contains(p.naturalKey) {
                #expect((p.possibleMatchName ?? "").isEmpty)
            }

            // It does not empty the drawer. Dan has genuine near-misses he still needs to answer, and a
            // pass that cleared every flag would pass every assertion above while destroying the feature.
            #expect(after.contains { !($0.possibleMatchName ?? "").isEmpty },
                    "the real possible matches survive")

            // It writes nothing but the flag: the relationship the scout stored is untouched, so no row
            // can be silently rescored or moved between stages by a launch tidy-up.
            for p in after {
                #expect(p.priorRelationship == relationshipsBefore[p.naturalKey])
            }

            // Idempotent across a relaunch.
            let reCtx = ModelContext(try openContainer(at: storeCopy))
            #expect(PossibleMatchRecheck.run(in: reCtx, loadInputs: realInputs) == 0)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
