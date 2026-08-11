import Testing
import Foundation
import SwiftData

// #2451: the four realignment passes rehearsed against a COPY of Dan's real store, with a before and
// after row count per table, before any of them is allowed to run at his next launch.
//
// A migration that has only ever met fresh fixtures is a migration nobody has tried. The rows here are
// refusals he made by hand, answers he paid for and corrections he typed, and a pass that lost one
// would cost him something he would have to notice was gone before he could remake it (L7). So the
// whole set is run together, in the launch's own order, against a WAL-consistent clone.
//
// Nothing here writes to the live store. `LiveStoreClone` takes the copy through SQLite's own online
// backup and refuses outright to hand back the live path (L2), and every write below lands in a
// throwaway directory this test deletes.
//
// WHAT IT ASSERTS versus WHAT IT PRINTS. The assertions are INVARIANTS: no table loses a row it may not
// lose, every organisation-scoped refusal that survives still reads as refused, and a second pass over
// the rehearsed store does nothing. The COUNTS are printed as the rehearsal record and pinned by
// nothing, because a pinned count stays green while the thing it stands for moves (L63).
@Suite("The realignment passes, rehearsed on a copy of the live store (#2451)")
struct KeyRealignmentLiveStoreTests {

    private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private struct Census: Equatable {
        var refusals = 0
        var organisationRefusals = 0
        var reachabilityAnswers = 0
        var venuePlaceAnswers = 0
        var promoted = 0
        var demoted = 0
    }

    private func census(_ context: ModelContext) throws -> Census {
        let refusals = try context.fetch(FetchDescriptor<RefusedContactAddress>())
        return Census(
            refusals: refusals.count,
            organisationRefusals: refusals.filter {
                $0.scopeRaw == ContactRefusal.Scope.organisationRaw }.count,
            reachabilityAnswers: try context.fetch(FetchDescriptor<OrgReachabilityAnswer>()).count,
            venuePlaceAnswers: try context.fetch(FetchDescriptor<VenuePlaceAnswer>()).count,
            promoted: try context.fetch(FetchDescriptor<PromotedProducer>()).count,
            demoted: try context.fetch(FetchDescriptor<DemotedHouse>()).count)
    }

    // LIVE-STORE-CLAIM verified=2026-08-10 measure="rows in every table holding a stored fold key, counted before and after the four realignment passes run together against a clone of the Release store"
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theFourPassesAreRehearsedAgainstDansRealRows() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("realignment-2451-\(UUID().uuidString)", isDirectory: true)
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

            let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self,
                                 RefusedContactAddress.self, OrgReachabilityAnswer.self,
                                 VenuePlaceAnswer.self, PromotedProducer.self, DemotedHouse.self])
            let context = ModelContext(try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: clone,
                                                    cloudKitDatabase: .none)]))

            let before = try census(context)
            let refusalsBefore = try context.fetch(FetchDescriptor<RefusedContactAddress>())
                .map { (scopeRaw: $0.scopeRaw, scopeId: $0.scopeId, handleKey: $0.handleKey) }

            // In the launch's own order, so the rehearsal answers the question the launch will ask.
            let org = OrgKeyRealignmentMigration.run(in: context)
            let venue = VenueKeyRealignmentMigration.run(in: context)
            let overrides = ProducerOverrideKeyRealignment.run(in: context)
            let refusals = RefusedOrgKeyRealignment.run(in: context)
            try context.save()

            let after = try census(context)

            var out: [String] = []
            out.append("")
            out.append("=== P0.2 REALIGNMENT REHEARSAL (#2451), on a clone of the Release store ===")
            out.append("table                             before   after")
            out.append("RefusedContactAddress             \(before.refusals)        \(after.refusals)"
                       + "   (organisation-scoped: \(before.organisationRefusals) -> \(after.organisationRefusals))")
            out.append("OrgReachabilityAnswer.orgKey      \(before.reachabilityAnswers)        \(after.reachabilityAnswers)")
            out.append("VenuePlaceAnswer.venueKey         \(before.venuePlaceAnswers)        \(after.venuePlaceAnswers)")
            out.append("PromotedProducer.orgKey           \(before.promoted)        \(after.promoted)")
            out.append("DemotedHouse.orgKey               \(before.demoted)        \(after.demoted)")
            out.append("")
            out.append("OrgKeyRealignmentMigration:       \(org)")
            out.append("VenueKeyRealignmentMigration:     \(venue)")
            out.append("ProducerOverrideKeyRealignment:   \(overrides)")
            out.append("RefusedOrgKeyRealignment:         \(refusals)")
            out.append("=== END REHEARSAL ===")
            out.append("")
            print(out.joined(separator: "\n"))

            // THE INVARIANT THIS SUITE EXISTS FOR. The refusal ledger may never be shorter afterwards.
            #expect(after.refusals == before.refusals, Comment(rawValue:
                    "the rehearsal LOST \(before.refusals - after.refusals) refusals, which is the one "
                    + "thing the protective pass exists to make impossible"))

            // Every refusal that was there still answers, under whichever key it now carries. Rebuilt
            // from the rows AFTER the pass rather than from the values read before it, so the two sides
            // of the check do not come from one lookup (L70).
            let rowsAfter = try context.fetch(FetchDescriptor<RefusedContactAddress>())
            let ledger = ContactRefusal.Ledger(rows: rowsAfter.map {
                ContactRefusal.Ledger.Row(scopeRaw: $0.scopeRaw, scopeId: $0.scopeId,
                                          handleKey: $0.handleKey)
            })
            for row in rowsAfter where !row.handleKey.hasPrefix(ContactRefusal.Ledger.formHandlePrefix) {
                let refused = ledger.isRefused(
                    email: row.handleKey,
                    showKey: row.scopeRaw == ContactRefusal.Scope.showRaw ? row.scopeId : nil,
                    orgKey: row.scopeRaw == ContactRefusal.Scope.organisationRaw ? row.scopeId : nil)
                #expect(refused, "\(row.handleKey) survived the pass but no longer reads as refused")
            }

            // A SHOW-scoped refusal must be exactly where it was. Its `scopeId` is a natural key, and a
            // pass that folded one would move a strike onto a key naming nothing.
            let showsBefore = Set(refusalsBefore.filter { $0.scopeRaw == ContactRefusal.Scope.showRaw }
                .map(\.scopeId))
            let showsAfter = Set(rowsAfter.filter { $0.scopeRaw == ContactRefusal.Scope.showRaw }
                .map(\.scopeId))
            #expect(showsBefore == showsAfter, "a show-scoped refusal was re-keyed")

            // No row is left parked. A parked id would mean the pass died between its two halves, and the
            // row would be invisible to every lookup until the next launch re-derived it.
            #expect(!rowsAfter.contains { $0.id.contains("\u{1}") },
                    "a refusal was left parked mid-pass")

            // And a second run over the rehearsed store does nothing at all, which is what makes running
            // these every launch safe.
            let second = (OrgKeyRealignmentMigration.run(in: context),
                          VenueKeyRealignmentMigration.run(in: context),
                          ProducerOverrideKeyRealignment.run(in: context),
                          RefusedOrgKeyRealignment.run(in: context))
            #expect(second.0 == OrgKeyRealignmentMigration.Summary())
            #expect(second.1 == VenueKeyRealignmentMigration.Summary())
            #expect(second.2 == ProducerOverrideKeyRealignment.Summary())
            #expect(second.3 == RefusedOrgKeyRealignment.Summary())
            #expect(try census(context) == after, "a second pass changed the store")

            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
