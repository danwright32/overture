import Testing
import Foundation
import SwiftData
@testable import Overture

// #1761: prove the widened merge against a COPY of Dan's real store before it ever runs against his own.
// This pass DELETES rows, and #1761 widened what it can reach from "one night, one room" to "one night",
// so "it works on two hand-built rows" is not the claim that matters. The claim that matters is what it
// does to his 742.
//
// LIVE-STORE-CLAIM verified=2026-07-30 measure="same-night groups whose titles confidently match, the duplicate rows they hold, and what the pass leaves behind"
// Measured 2026-07-30: 26 groups holding 32 duplicate rows, of which the pass as it stood caught 3. Every
// one of the 26 was read by hand and is one show. Those counts are recorded here and NOT asserted, on
// purpose: the pass runs at every launch, so the moment it runs on Dan's own store the duplicates are
// gone and any test asserting "26 still exist" goes red BECAUSE the fix worked. What is asserted below is
// the INVARIANT, which holds both before and after: once the pass has run, no night may still hold two
// rows whose titles confidently match, unless the deferral rule deliberately left them.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a pass.
@Suite("Same-night room variant merge, live store (#1761)")
struct SameNightRoomVariantMergeLiveStoreTests {
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

    private func openContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    private func dated(_ rows: [Prospect]) -> [Prospect] {
        rows.filter { ($0.performanceDate ?? "").isEmpty == false }
    }

    // The invariant. After the pass, any two rows left sharing a night must NOT confidently match by
    // title, or must be a pair the deferral rule deliberately kept (both carrying outreach history).
    @Test(.enabled(if: liveStoreExists))
    func afterThePassNoNightStillHoldsTwoCopiesOfOneShow() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overture-1761-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ctx = ModelContext(try openContainer(at: try copyLiveStore(to: dir)))
        SameNightTitleVariantMerge.run(in: ctx)
        try ctx.save()

        let remaining = dated((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? [])
        var offenders: [String] = []
        for (_, night) in Dictionary(grouping: remaining, by: { $0.performanceDate ?? "" }) {
            for i in night.indices {
                for j in night.indices where j > i {
                    guard GroupNameMatch.isConfident(
                        night[i].groupName, night[j].groupName,
                        minimumContainment: GroupNameMatch.sameNightContainmentFraction) else { continue }
                    let bothHaveHistory = NaturalKeyVenueMigration.hasOutreachHistory(night[i])
                        && NaturalKeyVenueMigration.hasOutreachHistory(night[j])
                    guard !bothHaveHistory else { continue }
                    offenders.append("\(night[i].performanceDate ?? "") "
                                     + "\(night[i].groupName) @ \(night[i].venue ?? "") | "
                                     + "\(night[j].groupName) @ \(night[j].venue ?? "")")
                }
            }
        }

        let sample = offenders.prefix(5).joined(separator: " // ")
        #expect(offenders.isEmpty,
                "the pass left \(offenders.count) duplicate pair(s) on one night: \(sample)")
    }

    // The safety claim, against real rows rather than invented ones: the pass must never delete a row
    // holding outreach Dan actually sent. Counted before and after on the same copy.
    @Test(.enabled(if: liveStoreExists))
    func thePassNeverDeletesARowCarryingOutreachHistory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overture-1761-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ctx = ModelContext(try openContainer(at: try copyLiveStore(to: dir)))
        let before = ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? [])
            .filter(NaturalKeyVenueMigration.hasOutreachHistory).count

        SameNightTitleVariantMerge.run(in: ctx)
        try ctx.save()

        let after = ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? [])
            .filter(NaturalKeyVenueMigration.hasOutreachHistory).count
        #expect(after == before,
                "the merge dropped \(before - after) row(s) carrying real outreach history")
    }

    // A merge that keeps a row but blanks its room would read on the card as a show with nowhere to be.
    // Every row that survives must still name a venue if it named one before.
    @Test(.enabled(if: liveStoreExists))
    func everySurvivingRowStillNamesItsRoom() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overture-1761-rooms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ctx = ModelContext(try openContainer(at: try copyLiveStore(to: dir)))
        let namedBefore = ((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? [])
            .filter { ($0.venue ?? "").isEmpty == false }.count

        SameNightTitleVariantMerge.run(in: ctx)
        try ctx.save()

        let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let blanked = rows.filter { ($0.venue ?? "").isEmpty }
        #expect(namedBefore > 0, "the live store should hold rows naming a venue")
        #expect(blanked.isEmpty,
                "\(blanked.count) surviving row(s) lost their venue in the merge")
    }
}
