import Testing
import Foundation
import SwiftData

// #4055: the token half of `DriftedRunMerge` rehearsed against a COPY of Dan's real store, and REPORTED,
// before it is allowed to delete a row at his next launch.
//
// #4029 stopped new token duplicates being minted; it cannot reach rows already stored, because an ingest
// arm only runs when a night ARRIVES (L389). Those rows are this pass's job. But this pass DELETES, and
// the rows it will meet are ones Dan has decided about: one of the two live pairs holds a card he pitched.
// A correction over live rows with outreach on them is not something to run and then inspect (#4055).
//
// Nothing here writes to the live store. `LiveStoreClone` takes the copy through SQLite's own online
// backup and refuses outright to hand back the live path (L2), and every write lands in a throwaway
// directory this test deletes.
//
// WHAT IT ASSERTS versus WHAT IT PRINTS. The assertion is the INVARIANT that matters for a deleting pass:
// no row that reached the outside world is deleted, and a second run does nothing. The counts are printed
// as the rehearsal record and pinned by nothing, because a pinned count stays green while the thing it
// stands for moves (L63).
@Suite("The production token merge, rehearsed on a copy of the live store (#4055)")
struct ProductionTokenMergeLiveStoreTests {

    private static var liveStoreExists: Bool {
        LiveStoreClone.liveStoreURL != nil
    }

    // LIVE-SHAPE: the pairs this pass will meet, measured 2026-09-20 over a WAL inclusive clone.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theTokenMergeIsRehearsedAgainstDansRealRows() async throws {
        await RealStoreTestLock.shared.acquire()
        defer { Task { await RealStoreTestLock.shared.release() } }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("token-merge-4055-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A nil clone here is a FAILURE, not an absence: this test is gated on the live store existing,
        // so reaching this line means the COPY failed, and returning quietly would report green having
        // rehearsed nothing at all (L10, L98).
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            Issue.record("the live store exists but could not be cloned, so nothing was rehearsed")
            return
        }

        let schema = Schema([Prospect.self, Recipient.self])
        let context = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)]))

        let before = try context.fetch(FetchDescriptor<Prospect>())
        // Identified by what they ARE rather than by pk, so this keeps meaning something as the store
        // grows and the numbers move (L15).
        let reachedTheOutsideWorld = Set(before
            .filter { $0.sentAt != nil || $0.recipients.contains(where: \.wasWrittenTo) }
            .map(\.naturalKey))

        let summary = DriftedRunMerge.run(in: context)
        try context.save()

        let after = try context.fetch(FetchDescriptor<Prospect>())
        let survived = Set(after.map(\.naturalKey))

        // THE INVARIANT. A pass that deletes must never delete a row that reached the outside world: its
        // send record, its thread and Dan's own decision go with it, and he would have to notice it was
        // gone before he could remake it (L7). `mustDefer` is what is supposed to prevent this, so this
        // is the check that it actually does, on the real rows rather than on a fixture.
        let lost = reachedTheOutsideWorld.subtracting(survived)
        #expect(lost.isEmpty, """
            the rehearsal DELETED \(lost.count) row(s) that had been written to, which mustDefer exists \
            to prevent: \(lost.sorted())
            """)

        // And it settles: a second run over the rehearsed store must find nothing left to do, or the pass
        // would act again at every launch forever and the log would keep announcing work nobody asked for.
        let second = DriftedRunMerge.run(in: context)
        #expect(second.duplicatesDeleted == 0, "the pass does not settle: a second run deleted more rows")

        var out: [String] = []
        out.append("")
        out.append("=== #4055 TOKEN MERGE REHEARSAL, on a clone of the Release store ===")
        out.append("prospect rows before:      \(before.count)")
        out.append("prospect rows after:       \(after.count)")
        out.append("rows that were written to: \(reachedTheOutsideWorld.count) (none of which may be deleted)")
        out.append("duplicates deleted:        \(summary.duplicatesDeleted)")
        out.append("conflicts deferred:        \(summary.conflictsDeferred) (left for Dan, not merged)")
        out.append("second run deleted:        \(second.duplicatesDeleted) (must be 0)")
        for key in Set(before.map(\.naturalKey)).subtracting(survived).sorted() {
            out.append("  deleted: \(key)")
        }
        out.append("=== END REHEARSAL ===")
        out.append("")
        print(out.joined(separator: "\n"))
    }
}
