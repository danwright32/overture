import Testing
import Foundation
import SwiftData

// #1800: the same overlap rules, asked of Dan's real store rather than of shows a test invented.
//
// The synthetic suite pins the rules against states written to exercise them, which is the only way to
// cover a state the store does not currently hold. What it cannot do is notice that the store holds a
// state nobody thought to write: the instance behind this issue was exactly that, one show among 507
// carrying a guard flag from a path (#1585's triage check) that did not exist when the stage rule was
// written. So the rules are asked of the real rows too.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("No show in the real store is counted twice (#1800)")
struct StageOverlapLiveStoreTests {
    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
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

    // LIVE-STORE-CLAIM verified=2026-08-01 measure="shows matching more than one stage focus at once, and send problems on shows nothing was ever sent to"
    // Measured before the fix: 723 prospects, 507 not dismissed, and exactly one show in two focuses at
    // once (Raging of the Shrews, Under St Marks, Aug 14: untriaged AND reported as a send problem, with
    // nothing ever sent to it). Asserted as an invariant rather than as that count, because the count
    // moves with every scout while the rule does not.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theRealStoreObeysTheOverlapRules() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("stage-overlap-\(UUID().uuidString)",
                                                                   isDirectory: true)
            defer { try? fm.removeItem(at: dir) }
            let url = try copyLiveStore(to: dir)
            let schema = Schema([Prospect.self, Recipient.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))

            let live = try context.fetch(FetchDescriptor<Prospect>()).filter { $0.status != .dismissed }
            let violations = StageOverlap.violations(in: live)

            let named = violations.prefix(5)
                .map { "\($0.key) [\($0.rule.rawValue)] \($0.focuses)" }
                .joined(separator: "; ")
            #expect(violations.isEmpty,
                    "\(violations.count) of \(live.count) live shows break a stage overlap rule: \(named)")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
