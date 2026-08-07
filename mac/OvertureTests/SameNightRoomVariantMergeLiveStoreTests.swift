import Testing
import Foundation
import SwiftData

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

    // #1672: through the ONE shared clone. Copying the .store, its -wal and its -shm one file at a
    // time races a live writer, and a clone whose -wal does not match the .store beside it makes
    // whatever this suite concludes a statement about a torn copy rather than about Dan's data.
    // LiveStoreClone takes it through SQLite's online backup instead.
    private func copyLiveStore(to dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return clone
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

    // #1845's own guard, and the reason that issue was opened: one show must never sit in the QUEUE twice
    // at two different ranks. The score is a pure function of seven axes, four of which the presenter
    // string alone decides, so two copies of one show that were read from different pages disagree by up
    // to 8 points, which is the distance between the top of Dan's queue and the bottom of it.
    //
    // LIVE-STORE-CLAIM verified=2026-08-03 measure="same-night confident-title groups of untriaged rows whose stored fit scores differ, after the merge pass has run"
    // Measured on the live store: 3 such pairs before this change (2 against 10 in each), all three stuck
    // in the merge's deferral branch on every launch. Scoped to untriaged rows on purpose, because that is
    // what "in the queue" means, and because a pair Dan has already refused for two DIFFERENT reasons is
    // deliberately left alone (the merge will not choose between his reasons) and is not in front of him.
    @Test(.enabled(if: liveStoreExists))
    func afterThePassNoShowSitsInTheQueueTwiceAtTwoDifferentRanks() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overture-1845-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ctx = ModelContext(try openContainer(at: try copyLiveStore(to: dir)))
        SameNightTitleVariantMerge.run(in: ctx)
        try ctx.save()

        let queued = dated((try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []).filter { $0.status == .new }
        var offenders: [String] = []
        for (_, night) in Dictionary(grouping: queued, by: { $0.performanceDate ?? "" }) {
            for i in night.indices {
                for j in night.indices where j > i {
                    guard GroupNameMatch.isConfident(
                        night[i].groupName, night[j].groupName,
                        minimumContainment: GroupNameMatch.sameNightContainmentFraction) else { continue }
                    guard night[i].fitScore != night[j].fitScore else { continue }
                    offenders.append("\(night[i].performanceDate ?? "") \(night[i].groupName): "
                                     + "\(night[i].fitScore) against \(night[j].fitScore)")
                }
            }
        }

        let sample = offenders.prefix(5).joined(separator: " // ")
        #expect(offenders.isEmpty,
                "\(offenders.count) show(s) sit in the queue twice at two different ranks: \(sample)")
    }

    // The safety claim, against real rows rather than invented ones: the pass must never delete a row
    // holding outreach Dan actually sent. Counted before and after on the same copy.
    //
    // #1845: this used to count with `hasOutreachHistory`, which is true of a bare dismissal and of an
    // address a paid check merely FOUND. That is a PROXY for the claim in the sentence above, not the
    // claim itself, and the two came apart the moment the merge was allowed to collapse duplicates whose
    // only record was a found address: the pass correctly deleted 10 such rows and this guard read it as
    // 10 lost outreach records. It now counts the thing it exists to protect. The broad count is asserted
    // too, as a floor rather than an equality, so a change here still has to be deliberate.
    @Test(.enabled(if: liveStoreExists))
    func thePassNeverDeletesARowThatReachedTheOutsideWorld() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overture-1761-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ctx = ModelContext(try openContainer(at: try copyLiveStore(to: dir)))
        func reachedOutside(_ rows: [Prospect]) -> Int {
            rows.filter { NaturalKeyVenueMigration.hasRecordBeyondADismissal($0, countingFoundAddresses: false) }
                .count
        }
        let rowsBefore = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let before = reachedOutside(rowsBefore)
        let anyHistoryBefore = rowsBefore.filter(NaturalKeyVenueMigration.hasOutreachHistory).count

        SameNightTitleVariantMerge.run(in: ctx)
        try ctx.save()

        let rowsAfter = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
        let after = reachedOutside(rowsAfter)
        let anyHistoryAfter = rowsAfter.filter(NaturalKeyVenueMigration.hasOutreachHistory).count
        #expect(after == before,
                "the merge dropped \(before - after) row(s) that had reached the outside world")
        #expect(anyHistoryAfter <= anyHistoryBefore,
                "the merge cannot invent history: \(anyHistoryBefore) before, \(anyHistoryAfter) after")
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
