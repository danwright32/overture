import Testing
import Foundation
import SwiftData

// #1825: the listing link's label used to compare the row's own URL against `runSourceURLs`, which
// `RunGrouping` fills from the run members' OWN listing URLs. A row is therefore always inside its own
// run, so the comparison matched on all but 10 of the live store's 702 linked rows and announced a
// single show's page as the venue's calendar 639 times.
//
// These pin the two halves of that, measured against the real store rather than argued: the fact the
// label now reads separates the rows, and the fact it used to read cannot. Separate tests, because they
// fail for different reasons and one status shared between them would let a pass hide a failure (L53).
//
// Gated on the live store existing, so a machine without one reports a visible SKIP rather than a silent
// pass. Reads a copy and writes nothing anywhere.
@Suite("What the listing link label keys on (#1825)")
struct ListingLinkLabelLiveStoreTests {
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
        let schema = Schema([Prospect.self, Recipient.self, WatchedSource.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema,
                                                                      url: url, cloudKitDatabase: .none)])
    }

    private func canonical(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }


    // Everything the two tests below measure, read once from one copy of the store.
    private struct Measured {
        var linked: Int
        var byOldRule: Int
        var bySourceCalendar: Int
    }

    private func measure() async throws -> Measured {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("overture-1825-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let storeCopy = try copyLiveStore(to: scratch)

        let ctx = ModelContext(try openContainer(at: storeCopy))
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())

        var calendarBySourceId: [String: String] = [:]
        for s in sources where !(s.listingsURL ?? "").isEmpty {
            calendarBySourceId[s.sourceId] = canonical(s.listingsURL!)
        }

        let linked = all.filter { !($0.sourceListingURL ?? "").isEmpty }
        let byOldRule = linked.filter { p in
            let n = canonical(p.sourceListingURL!)
            return p.runSourceURLs.contains { canonical($0) == n }
        }
        let byCalendar = linked.filter { p in
            let n = canonical(p.sourceListingURL!)
            return p.sourceIds.contains { calendarBySourceId[$0] == n }
        }
        return Measured(linked: linked.count, byOldRule: byOldRule.count,
                        bySourceCalendar: byCalendar.count)
    }

    // LIVE-STORE-CLAIM verified=2026-08-01 measure="linked rows whose listing URL is the watched source's own calendar address"
    // The fact the label reads now. Measured at 53 of 702 linked rows: a real minority, which is what a
    // fallback link should be. Asserted as a band rather than the exact number, because the store moves
    // every night; the point is that it separates the rows instead of answering the same way for all of
    // them, which is precisely how the old rule managed to look sensible while being wrong.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theSourcesOwnCalendarSeparatesRowsInsteadOfMatchingThemAll() async throws {
        // #2198: released INLINE on both paths, never from a Task. A `defer { Task { ... } }` hands the
        // release to an unstructured task that runs after the test has returned, so the critical section
        // is not exclusive at all, which is #2190: the process died partway and three consecutive runs
        // each blamed a different innocent test while 600 to 1,500 tests silently never ran (#2195).
        await RealStoreTestLock.shared.acquire()
        do {
            let m = try await measure()
            #expect(m.linked > 100, "the live store still holds a real queue to measure")
            #expect(m.bySourceCalendar > 0,
                "no row falls back to its source's calendar, so the label can never say Venue calendar")
            #expect(m.bySourceCalendar < m.linked / 2,
                    "the calendar fallback is the exception, not most of the queue: \(m.bySourceCalendar) of \(m.linked)")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // LIVE-STORE-CLAIM verified=2026-08-01 measure="linked rows whose own listing URL appears in their own runSourceURLs"
    // The fact the label used to read, pinned so the mistake cannot be made again. Measured at 692 of 702:
    // a row is inside its own run by construction, so this can never distinguish anything. If a future
    // change points the label back at runSourceURLs, this is the test that says why it cannot work.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func aRowsOwnRunUrlsCannotTellItApartFromACalendarLink() async throws {
        await RealStoreTestLock.shared.acquire()   // #2198: released inline on both paths, never from a Task
        do {
            let m = try await measure()
            #expect(m.linked > 100, "the live store still holds a real queue to measure")
            #expect(m.byOldRule > m.linked * 9 / 10,
                "runSourceURLs is expected to match nearly every row: \(m.byOldRule) of \(m.linked)")
            #expect(m.byOldRule > m.bySourceCalendar * 2,
                    "the two facts must stay visibly different, or this guard has stopped proving anything")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
