import Testing
import Foundation
import SwiftData

// What ShowLink's rule actually does to Dan's own store, measured through the SHIPPED predicate.
//
// WHY THIS EXISTS RATHER THAN THE SCRIPT. `scripts/derive-showlink-shape.sh` answers the same question
// and is the one anybody can run, but it is an APPROXIMATION and says so on every run: it reads the
// folded title and venue back out of each row's stored `ZNATURALKEY` and clusters them in Python,
// because no SQLite expression can run `TitleNormalization.normalizeForKey` or decode an
// NSKeyedArchiver night blob. Every figure this milestone has quoted so far came from that route or
// from SQL written beside the app, and the gate on the plan (#3772) found three of them wrong.
//
// So this is the check that the approximation and the shipped rule agree. It runs ShowLink itself over
// a WAL-inclusive clone after a launch replay, prints the shape, and asserts the INVARIANTS rather than
// the store's current contents: a count pinned here would go red on an ordinary day as the store grows
// and would block every push in the repo (#3496, constraint 11).
@MainActor
@Suite("The shape ShowLink finds in the live store (milestone 62)")
struct ShowLinkCorpusShapeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated private static var liveStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }
    nonisolated private static var liveStoreExists: Bool {
        FileManager.default.fileExists(atPath: liveStoreURL.path)
    }

    private func container(at url: URL) throws -> ModelContainer {
        let schema = Schema([Prospect.self, Recipient.self])
        return try ModelContainer(for: schema,
                                  configurations: [ModelConfiguration(schema: schema, url: url,
                                                                      cloudKitDatabase: .none)])
    }

    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theGroupingHoldsItsInvariantsOverTheWholeLiveStore() async throws {
        // Released INLINE on every path, never from a `defer { Task { ... } }`: that is a promise to
        // release after this test has returned and the next suite has already started building its
        // container (#2190/#2195). THREE paths, and the early return when there is no live store to
        // clone is the one a do/catch alone does not cover.
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "showlink-corpus-shape")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                return
            }
            let ctx = ModelContext(try container(at: clone))
            LaunchReplay.run(in: ctx, handoffDirectory: try sandboxes.make(named: "showlink-handoff"))
            try ctx.save()

            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let today = QueueModel.easternToday()
            let rows = all.map(ShowLink.Row.init)
            let onQueue = zip(all, rows)
                .filter { $0.0.status != .dismissed }
                .filter { ($0.0.runEndDate ?? $0.0.performanceDate ?? "") >= today }
                .map(\.1)

            let wholeStore = ShowLink.group(rows)
            let queueGroups = ShowLink.group(onQueue)
            let queueMisses = ShowLink.nearMisses(onQueue)

            // Printed so the figures quoted in #3772's correction round and in the milestone's issue
            // bodies can be re-taken from the shipped rule rather than from the approximation. A
            // printed line is not a detector and is not asked to be one: the assertions below are.
            print("ShowLink corpus shape: \(all.count) rows, \(onQueue.count) on the queue; "
                  + "\(distinctGroups(wholeStore)) group(s) over the whole store, "
                  + "\(distinctGroups(queueGroups)) on the queue, "
                  + "largest on the queue \(largest(queueGroups)); "
                  + "\(queueMisses.count) refused pair(s) on the queue")

            // INVARIANTS, each one a property of the rule that holds at any store size.

            // Membership is symmetric. If it were not, one card would list a sibling that does not list
            // it back, and which row Dan happened to open would decide what he saw.
            for (id, others) in wholeStore {
                for other in others {
                    #expect(wholeStore[other]?.contains(id) == true,
                            "\(id) names \(other) as the same show but not the other way round")
                }
            }

            // Nothing is its own sibling, which a union-find bug would produce silently.
            for (id, others) in wholeStore {
                #expect(!others.contains(id), "\(id) is listed as a sibling of itself")
            }

            // Every joined pair really does share the folded title and the folded venue. This is the
            // one that would catch a bucket key built from the wrong fields, which is the defect the
            // plan's own prose would have produced (#3772, claim 6).
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            for (id, others) in wholeStore {
                guard let row = byID[id] else { continue }
                for other in others {
                    guard let sibling = byID[other] else { continue }
                    #expect(ShowLink.foldedTitle(row.groupName) == ShowLink.foldedTitle(sibling.groupName))
                    #expect(ShowLink.foldedVenue(row.venue) == ShowLink.foldedVenue(sibling.venue))
                }
            }

            // A refused pair is never also a joined one. The two answers come from one walk, and if
            // they could disagree the duplicate report would ask Dan about rows already on one card.
            for miss in ShowLink.nearMisses(rows) {
                #expect(wholeStore[miss.a]?.contains(miss.b) != true,
                        "\(miss.a) and \(miss.b) are reported as both joined and refused")
            }

            // The queue is a SUBSET of the store, so it can never find a group the store does not.
            // This is what would have caught the plan sending somebody to screenshot a queue group
            // that is really five dismissed rows (#3772, claim 3).
            #expect(distinctGroups(queueGroups) <= distinctGroups(wholeStore))

            try? FileManager.default.removeItem(at: clone)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    private func distinctGroups(_ grouped: [String: [String]]) -> Int {
        Set(grouped.map { Set([$0.key] + $0.value) }).count
    }

    private func largest(_ grouped: [String: [String]]) -> Int {
        grouped.values.map { $0.count + 1 }.max() ?? 0
    }
}
