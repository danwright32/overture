import Testing
import Foundation
import SwiftData

// #2565: the corrective pass rehearsed against COPIES of Dan's real store before it is allowed to lower
// anything at his next launch.
//
// This is the one direction the launch's realignment refuses to move a row, so a fixture-only proof would
// say nothing about the rows it will actually meet. Nothing here writes to the live store or to a backup:
// `LiveStoreClone` takes every copy through SQLite's own online backup and refuses outright to hand back
// the live path (L2), and every write below lands in a throwaway directory these tests delete.
//
// TWO REHEARSALS, because the live store has already healed. The scout re-read the rows #2508 lifted four
// days after the issue was filed, so today's store holds none of them, and a pass that moves nothing there
// is indistinguishable from a pass that CANNOT move anything (L98). The second rehearsal runs the same
// pass over every dated launch backup, which is the same real data on the days it was still wrong, and is
// also exactly the state a restore would put back.
//
// WHAT THEY ASSERT versus WHAT THEY PRINT. The assertions are INVARIANTS: no row Dan overrode is touched,
// nothing is LIFTED by a pass that exists to lower, the count and the rows it promises agree, and a second
// pass does nothing. The counts are printed as the rehearsal record and pinned by nothing, because a
// pinned count stays green while the thing it stands for moves (L63).
@Suite("The fragment-match correction, rehearsed on copies of the live store (#2565)")
struct FragmentMatchCorrectionLiveStoreTests {

    private static var liveStoreExists: Bool {
        LiveStoreClone.liveStoreURL != nil
    }

    private struct Axes: Equatable {
        var key: String
        var production: String
        var profile: String
        var coverage: String
        var fitScore: Int
        var overridden: Bool
        var title: String
    }

    private func axes(_ context: ModelContext) throws -> [Axes] {
        try context.fetch(FetchDescriptor<Prospect>()).map {
            Axes(key: $0.naturalKey, production: $0.production, profile: $0.profile,
                 coverage: $0.coverage, fitScore: $0.fitScore,
                 overridden: $0.classificationOverriddenByDan, title: $0.groupName)
        }
        .sorted { $0.key < $1.key }
    }

    private func open(_ store: URL) throws -> ModelContext {
        let schema = Schema([Prospect.self, Recipient.self, DayOff.self])
        return ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)]))
    }

    /// Runs the pass over one opened clone, asserts every invariant against it, and returns the report
    /// lines plus how many rows moved. One implementation, so the live rehearsal and the backup one
    /// cannot come to judge the same pass by different rules.
    @discardableResult
    private func rehearse(_ context: ModelContext, label: String) throws -> (lines: [String], moved: Int) {
        let before = try axes(context)
        #expect(!before.isEmpty, "\(label) holds no prospects at all, so nothing was rehearsed")

        let summary = FragmentMatchCorrection.run(in: context)
        try context.save()

        let after = try axes(context)
        let moved = zip(before, after).filter { $0 != $1 }

        var lines = ["\(label): \(before.count) rows, production lowered \(summary.productionLowered),"
                     + " profile lowered \(summary.profileLowered), rescored \(summary.rescored)"]
        for (was, now) in moved {
            lines.append("    \(now.title): \(was.production)/\(was.profile)/\(was.coverage)"
                         + " fit \(was.fitScore) -> \(now.production)/\(now.profile)/\(now.coverage)"
                         + " fit \(now.fitScore)")
        }

        // Every count the pass reports is checked against the rows it promises, read back out of the
        // store rather than taken from the report beside it (L16, L107). Each axis separately: a total
        // that agrees while an axis does not is exactly the reading a summed check cannot make.
        let profileMoved = moved.filter { $0.0.profile != $0.1.profile }.count
        let productionMoved = moved.filter { $0.0.production != $0.1.production }.count
        #expect(moved.count == summary.rescored, Comment(rawValue:
                "\(label): the pass reported rescoring \(summary.rescored) rows, \(moved.count) moved"))
        #expect(profileMoved == summary.profileLowered, Comment(rawValue:
                "\(label): the pass reported lowering \(summary.profileLowered) profiles,"
                + " \(profileMoved) rows changed profile"))
        #expect(productionMoved == summary.productionLowered, Comment(rawValue:
                "\(label): the pass reported lowering \(summary.productionLowered) productions,"
                + " \(productionMoved) rows changed production"))

        for (was, now) in moved {
            // Dan's own corrections are untouched, whatever the rules now say about them.
            #expect(!was.overridden, "\(label): \(now.title) was corrected by hand and this pass moved it")
            // Nothing is LIFTED. A pass that exists to lower must never be the thing that raises a row
            // into Dan's attention, and an agency row keeps its penalty.
            #expect(now.fitScore <= was.fitScore,
                    "\(label): \(now.title) came out of a lowering pass scoring higher")
            #expect(!(was.production == Production.unknown.rawValue
                      && now.production == Production.selfProduced.rawValue),
                    "\(label): \(now.title) was lifted to self-produced by the lowering pass")
            #expect(was.production != Production.agency.rawValue
                    || now.production == Production.agency.rawValue,
                    "\(label): \(now.title) lost its agency penalty")
            #expect(!(was.profile == Profile.neutral.rawValue
                      && now.profile == Profile.strong.rawValue),
                    "\(label): \(now.title) was lifted to a strong profile by the lowering pass")
        }

        // And a second run over the rehearsed store does nothing at all, which is what makes running this
        // every launch safe.
        let second = FragmentMatchCorrection.run(in: context)
        #expect(second == FragmentMatchCorrection.Summary(), "\(label): a second pass moved rows")
        #expect(try axes(context) == after, "\(label): a second pass changed the store")

        return (lines, moved.count)
    }

    // LIVE-STORE-CLAIM verified=2026-08-16 measure="prospect rows whose stored producer axes the pre-#2508 fragment match explains and the current classifier refuses, run against a clone of the Release store"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theCorrectionIsRehearsedAgainstDansRealRows() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("fragment-2565-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            // A nil clone here is a FAILURE, not an absence. This test is gated on the live store
            // existing, so reaching this line means the COPY failed, and returning quietly would report
            // green having rehearsed nothing at all (L10, L98).
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                Issue.record("the live store exists but could not be cloned, so nothing was rehearsed")
                return
            }

            let report = try rehearse(try open(clone), label: "the Release store as it stands")
            print("\n=== #2565 CORRECTION REHEARSAL ===\n"
                  + report.lines.joined(separator: "\n") + "\n=== END REHEARSAL ===\n")

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // LIVE-STORE-CLAIM verified=2026-08-16 measure="rows the correction moves in each dated launch backup of the Release store"
    // The rehearsal that has something to find. Measured 2026-08-16 over the ten backups then on disk,
    // the pass lowered 2 rows in the four taken on 2026-08-13 (`Let's Get Schooled!` from
    // self/strong/likely_uncovered at fit 6, and `Operation Mincemeat: Mission Recast` from the same at
    // fit 8, both to self/neutral/unknown) and 0 in the six taken from 2026-08-14 on, by which time an
    // ordinary re-scout had already corrected them.
    //
    // That measurement is NOT pinned here, deliberately: rotation keeps the last ten, so the backups
    // carrying the defect age out, and a pinned count would fail for the passage of time rather than for
    // anything about the code (L63, L130). What is asserted is that at least one backup was actually
    // opened and rehearsed, and that every invariant above holds on all of them.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theCorrectionIsRehearsedAgainstTheLaunchBackups() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("fragment-2565-backups-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let backups = LiveStoreClone.launchBackupStores
            #expect(!backups.isEmpty,
                    "the live store exists but no launch backup does, which is itself worth knowing")

            var lines: [String] = []
            var rehearsed = 0
            var totalMoved = 0
            for backup in backups {
                let stamp = backup.deletingLastPathComponent().lastPathComponent
                // An older backup can carry a schema this build cannot open. That is reported as its own
                // outcome and never counted as a clean rehearsal (L11).
                do {
                    let clone = try LiveStoreClone.makeClone(ofBackupAt: backup, in: dir)
                    let report = try rehearse(try open(clone), label: "backup \(stamp)")
                    lines.append(contentsOf: report.lines)
                    totalMoved += report.moved
                    rehearsed += 1
                } catch {
                    lines.append("backup \(stamp): NOT REHEARSED, could not be opened (\(error))")
                }
            }

            print("\n=== #2565 CORRECTION REHEARSAL, over \(backups.count) launch backups ===\n"
                  + lines.joined(separator: "\n")
                  + "\nrehearsed \(rehearsed) of \(backups.count), rows moved in total \(totalMoved)"
                  + "\n=== END REHEARSAL ===\n")

            #expect(rehearsed > 0, "not one launch backup could be opened, so nothing was rehearsed")

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
