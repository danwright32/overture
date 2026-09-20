import Testing
import Foundation
import SwiftData

// #3328, the half that is left.
//
// WHAT ALREADY SHIPPED, established before anything was built here, because two of this issue's three
// stated defects are gone and building to the write-up would have rebuilt them (the milestone's own
// recorded hazard):
//
//   - "7 of 15 merges kept the worse copy, 4 of them keeping a card the feed has STOPPED LISTING" was
//     measured 2026-08-30. `NaturalKeyVenueMigration.stillInTheFeed` landed 2026-09-06 (#3582) as a
//     rung ABOVE age, so being listed now outranks being old and those four can no longer happen.
//   - "the merge should adopt the live copy's identity, or the next scout mints the duplicate again"
//     is `SurvivorInheritance.carry` (#3379), wired into this pass at its delete site.
//
// WHAT IS LEFT is the smaller case the premise re-check on that issue names: where BOTH rows are still
// listed, `stillInTheFeed` cannot separate them, the ladder falls to `candidates[0]`, and that is
// oldest wins. No rung reads `fitScore`, so the survivor can be the lower-scoring read of one show.
//
// THIS MEASURES IT RATHER THAN ASSUMING IT, by the issue's own method: run the REAL pass over a clone
// and compare before with after. Re-spelling the clustering rule here would be a second definition of
// the population and would disagree with the pass in whichever direction flattered the argument
// (L107), which is exactly how this issue's original figures aged.
//
// It REPORTS. It does not assert a rung that does not exist, and it does not assert the count, because
// the count moves with every scout.
//
// AND IT RUNS AGAINST THE DATED BACKUPS, NOT THE LIVE STORE, which is the correction that makes it
// mean anything. The first version cloned the live store and reported "0 duplicates deleted, 0 kept a
// lower score". That zero was worthless: `SameNightTitleVariantMerge` runs at every launch, so by the
// time a clone is taken the store has ALREADY been merged and there is nothing left to collapse. The
// ladder never ran, and a report saying nothing kept a lower score when nothing was chosen at all is
// the same defect this suite exists to measure, one level up (L98, L182).
//
// Its own guard missed it too, and that is worth recording rather than quietly fixing: the guard asked
// whether any cluster was SEEN, and five deferrals satisfied it. A deferral never reaches the ladder.
// The guard now asks whether the ladder CHOSE, which is the thing the report is about.
//
// `overture-store-backups/` holds a snapshot taken at the START of each launch, before that launch's
// migrations, so those stores still carry the duplicates the pass is about to collapse. That is the
// only place the ladder can be watched working.
@MainActor
@Suite("Which copy of one show survives the merge (#3328)")
final class SurvivorScoreLiveStoreTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated private static var liveStoreExists: Bool {
        FileManager.default.fileExists(
            atPath: StoreLocation.storeURL(appSupport: StoreLocation.appSupport,
                                           isDebugBuild: false).path)
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    private struct Before { let key: String; let title: String; let date: String
                            let score: Int; let missed: Int }

    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theMergeIsMeasuredForWhichCopyItKeeps() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let backupsRoot = StoreLocation.storeURL(appSupport: StoreLocation.appSupport,
                                                     isDebugBuild: false)
                .deletingLastPathComponent()
                .appendingPathComponent("overture-store-backups", isDirectory: true)
            // Only the plain yyyyMMdd-HHmmss shape. A `.foreign` folder is the #1410 evidence snapshot
            // of a file that was NOT Overture's, and a hand-made one carries no guarantee of shape.
            let dated = ((try? FileManager.default.contentsOfDirectory(atPath: backupsRoot.path)) ?? [])
                .filter { $0.count == 15 && $0.dropFirst(8).first == "-" && Int($0.prefix(8)) != nil }
                .sorted()
            guard !dated.isEmpty else {
                print("Survivor score: UNMEASURED, no dated backup to read.")
                await RealStoreTestLock.shared.release()
                return
            }
            // EVERY dated backup, not the newest one. One launch collapses one or two clusters, so a
            // single backup is a sample of one and cannot be told from noise (L395). Ten launches is a
            // population worth a verdict, and each clone plus pass costs about a second.
            var totalDeleted = 0
            var totalDeferred = 0
            var totalBothListed = 0
            var allLowerScoreKept: [(gone: Before, kept: Before)] = []
            for (index, stamp) in dated.enumerated() {
                let dir = try sandboxes.make(named: "survivor-score-\(index)")
                let clone = try LiveStoreClone.makeClone(
                    ofBackupAt: backupsRoot.appendingPathComponent(stamp)
                        .appendingPathComponent("Overture.store"),
                    in: dir)
                let ctx = ModelContext(try container(at: clone))

            // Before: every row this pass could touch, by the identity that survives a delete.
            var before: [String: Before] = [:]
            for p in try ctx.fetch(FetchDescriptor<Prospect>()) {
                before[p.naturalKey] = Before(key: p.naturalKey, title: p.groupName,
                                              date: p.performanceDate ?? "",
                                              score: p.fitScore, missed: p.missedScoutCount)
            }

            let summary = SameNightTitleVariantMerge.run(in: ctx)
            try ctx.save()

            let after = Set((try ctx.fetch(FetchDescriptor<Prospect>())).map(\.naturalKey))
            let deleted = before.values.filter { !after.contains($0.key) }

            // A deleted row and the survivor that replaced it share the night. Pairing on the night is
            // the pass's own outermost bucket, so this cannot pair two rows the pass never compared.
            var lowerScoreKept: [(gone: Before, kept: Before)] = []
            var bothWereListed = 0
            for gone in deleted {
                let survivors = before.values.filter {
                    after.contains($0.key) && $0.date == gone.date && $0.key != gone.key
                }
                guard let kept = survivors.max(by: { $0.score < $1.score }) else { continue }
                if gone.missed == 0 && kept.missed == 0 { bothWereListed += 1 }
                if kept.score < gone.score { lowerScoreKept.append((gone, kept)) }
            }

                totalDeleted += summary.duplicatesDeleted
                totalDeferred += summary.conflictsDeferred
                totalBothListed += bothWereListed
                allLowerScoreKept.append(contentsOf: lowerScoreKept)
            }

            // #3321: WHICH groups the pass refuses is NOT reported here, and the reason is worth
            // keeping. A first version of this block asked `NaturalKeyVenueMigration.mustDefer` about
            // every row sharing a night and printed the result. That is a SECOND definition of the
            // population: the pass asks it about a title-matched cluster, not about a night, so the
            // listing named dozens of groups the pass never considered and would have been quoted as
            // "the stuck groups" (L107, and the same trap this suite's own header warns about).
            //
            // The clustering that would make it right is private to the pass, deliberately. So the
            // deferred groups cannot be named from outside, and that is itself the finding: #3321 asks
            // for the pass to REPORT what it refused, and this is the evidence that no audit standing
            // beside it can substitute for that.

            print("Survivor score corpus: over \(dated.count) dated backup(s), "
                  + "\(totalDeleted) duplicate(s) deleted, \(totalDeferred) conflict(s) deferred; "
                  + "\(totalBothListed) pair(s) had BOTH rows still listed, "
                  + "\(allLowerScoreKept.count) kept a lower score")
            for pair in allLowerScoreKept.prefix(8) {
                print("    lowerScoreKept \(pair.gone.date): kept \(pair.kept.title) "
                      + "score=\(pair.kept.score) missed=\(pair.kept.missed) :: deleted "
                      + "\(pair.gone.title) score=\(pair.gone.score) missed=\(pair.gone.missed)")
            }

            // THE ONLY ASSERTION, and it is about the instrument rather than the store. A run that
            // collapsed nothing measured nothing, and a report that says "0 kept a lower score" after
            // examining no clusters is the reading this milestone has already been misled by twice
            // (L98, L182). `conflictsDeferred` counts too: a deferral is a cluster the pass SAW.
            #expect(totalDeleted > 0,
                    "the ladder CHOSE no survivor in this run, so a count of 'kept a lower score' counts nothing: a deferral never reaches the ladder, which is the distinction the first version of this guard missed")

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
