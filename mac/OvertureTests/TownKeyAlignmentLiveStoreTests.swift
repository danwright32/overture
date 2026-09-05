import Testing
import Foundation
import SwiftData

// #2499: are any stored town rows out of step with `ExcludedTownEditing.normalize`?
//
// That fold (trim plus lowercase) builds `ExcludedTown.town` and `AllowedSeedTown.town` and, unlike the
// other stored folds in the app, has NO realignment pass. A stranded row silently un-blocks a town Dan
// refused, which fails OPEN: the show comes back rather than disappearing, which is why #2499 is p3.
//
// Measured before anything was written that could touch his data, because a realignment pass is a
// destructive write and the question of whether one is needed at all is answerable read-only (L5).
//
// Read through `LiveStoreClone`, the same way every other live-store check here does: a `.backup` copy
// converted to a self-contained database, never the live file (L2).
@MainActor
@Suite("Stored town rows are aligned with their fold (#2499)")
struct TownKeyAlignmentLiveStoreTests {
    // The lock is released INLINE on both paths, never from inside a `Task`: releasing from a Task
    // leaves the critical section non-exclusive, so two suites can build a disk-backed container at
    // once and crash the whole process while reporting an innocent test (#2190/#2195). The first
    // version of this file did exactly that and `RealStoreLockPairingTests` refused it.
    @Test func noStoredTownIsOutOfStepWithTheFoldThatBuildsIt() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            try await measureTownAlignment()
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    private func measureTownAlignment() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("town-align-\(UUID().uuidString)",
                                                               isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // No live store is the ordinary state on a clone, in CI and in an agent worktree, and it is NOT
        // a pass: it is nothing measured, said out loud rather than folded into silence (L98, L11).
        guard let url = try LiveStoreClone.makeClone(in: dir) else {
            Issue.record(Comment(rawValue: """
                UNMEASURED: no live store on this machine, so whether any town row is out of step with \
                ExcludedTownEditing.normalize is unknown here. This is expected off Dan's Mac.
                """))
            return
        }

        let schema = Schema([ExcludedTown.self, AllowedSeedTown.self])
        let context = ModelContext(try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)]))

        let excluded = try context.fetch(FetchDescriptor<ExcludedTown>()).map(\.town)
        let allowed = try context.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town)

        let strays = (excluded + allowed).filter { $0 != ExcludedTownEditing.normalize($0) }
        #expect(strays.isEmpty, """
            \(strays.count) stored town row(s) do not match ExcludedTownEditing.normalize: \(strays.joined(separator: ", ")). Each one \
            silently un-blocks a town Dan refused, because the resolver compares normalized tokens and \
            these cannot match (#2499).
            """)

        // What was actually read, PRINTED rather than recorded as an issue: a green result over an empty
        // table and a green result over a full one are different facts, and only one of them measured
        // anything (L98). Zero towns is a legitimate state, so this reports rather than refusing.
        print("LIVE STORE TOWN KEYS: \(excluded.count) excluded, \(allowed.count) allowed, "
              + "\(strays.count) out of step with ExcludedTownEditing.normalize")
    }
}
