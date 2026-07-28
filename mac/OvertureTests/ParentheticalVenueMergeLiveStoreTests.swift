import Testing
import Foundation
import SwiftData
@testable import Overture

// #1686: prove the parenthetical fold and the survivor rule against a COPY of Dan's real store before
// either runs against his own. This pass DELETES rows, so "it works on two hand-built rows" is not the
// claim that matters; the claim that matters is what happens to his ten.
//
// Gated on the live store existing, so a machine without one reports a visible SKIP. Reads a copy.
@Suite("Parenthetical venue duplicates, live store (#1686)")
struct ParentheticalVenueMergeLiveStoreTests {
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

    // A show billed at one venue on one night, held twice.
    private struct Night: Hashable {
        let title: String
        let date: String
        let venueKey: String
    }

    private func nights(_ prospects: [Prospect]) -> [Night: [Prospect]] {
        Dictionary(grouping: prospects.filter { $0.performanceDate != nil }) {
            Night(title: TitleNormalization.normalizeForKey(Prospect.canonicalize($0.groupName)),
                  date: $0.performanceDate ?? "",
                  venueKey: VenueNormalization.normalizeForKey($0.venue ?? ""))
        }
    }

    // LIVE-STORE-CLAIM verified=2026-07-28 measure="stored pairs split by a parenthetical venue, and the fit score and prior relationship each row of the pair carries"
    // Measured 2026-07-28: five pairs, ten rows, every one untriaged. Four are Young New Yorkers' Chorus
    // nights scored 7 against 27 (the 7 predates #1216, which taught the matcher to read the presenter,
    // and the row was never re-matched because its key had split); the fifth is MASS MoCA, scored 1 both
    // ways. Each pair must become one row, and the row that survives must be the one carrying the current
    // verdict, not the stale one.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theStoredParentheticalPairsCollapseOntoTheRowThatIsUpToDate() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1686-live-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            let before = try ctx.fetch(FetchDescriptor<Prospect>())
            let doubledBefore = nights(before).filter { $0.value.count > 1 }
            // The defect is real on this store. Without this the test could pass on an empty store.
            #expect(!doubledBefore.isEmpty, "the live store still holds a night held twice")

            // Two populations, and only one of them may be merged. A night whose rows are all pristine is
            // a duplicate to collapse; a night where two rows EACH carry a decision of Dan's is #1639's
            // case, and this pass refuses it on purpose rather than reconciling two histories blind. The
            // live store holds both today, which is why the assertions below are split rather than a flat
            // "no night is doubled".
            let mergeable = doubledBefore.filter {
                $0.value.filter(NaturalKeyVenueMigration.hasOutreachHistory).count < 2
            }
            let deferrable = doubledBefore.filter {
                $0.value.filter(NaturalKeyVenueMigration.hasOutreachHistory).count >= 2
            }
            #expect(!mergeable.isEmpty, "the duplicates this issue is about are still here")
            // What each mergeable night's rows are worth, so the survivor is checked against the best of
            // them rather than against a number written here by hand.
            let bestScore = mergeable.mapValues { rows in rows.map(\.fitScore).max() ?? 0 }

            let summary = NaturalKeyVenueMigration.run(in: ctx)
            try ctx.save()

            let after = try ctx.fetch(FetchDescriptor<Prospect>())
            #expect(after.count == before.count - summary.duplicatesDeleted)
            #expect(summary.conflictsDeferred == deferrable.count)
            // Measured 2026-07-28 on the real store: 5 nights collapsed, 5 rows deleted, 1 re-keyed in
            // place, 2 conflicts deferred (both pre-existing #1639 pairs, dismissed on both sides). The
            // numbers are not asserted, since the store moves daily; the shape is.
            #expect(summary.duplicatesDeleted == mergeable.count)

            let nightsAfter = nights(after)
            // Every mergeable night is now one card, and it is the card carrying the best verdict its
            // rows held, so a merge can never leave Dan the copy that says he has not worked with a
            // group he has.
            for (night, best) in bestScore {
                let survivors = nightsAfter[night] ?? []
                #expect(survivors.count == 1)
                #expect(survivors.first?.fitScore == best)
            }
            // Nothing carrying two real decisions was touched.
            for (night, rows) in deferrable {
                #expect(nightsAfter[night]?.count == rows.count)
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // Idempotence against the real store, which matters more here than usual: this pass runs on EVERY
    // launch and deletes rows, so a second run that found more to delete would be quietly eating the
    // store one launch at a time.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func asecondPassOverTheRealStoreDeletesNothing() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory
                .appendingPathComponent("overture-1686-idem-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: scratch) }
            let storeCopy = try copyLiveStore(to: scratch)

            let ctx = ModelContext(try openContainer(at: storeCopy))
            _ = NaturalKeyVenueMigration.run(in: ctx)
            try ctx.save()

            let reCtx = ModelContext(try openContainer(at: storeCopy))
            let second = NaturalKeyVenueMigration.run(in: reCtx)
            #expect(second.duplicatesDeleted == 0)
            #expect(second.rekeyed == 0)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
