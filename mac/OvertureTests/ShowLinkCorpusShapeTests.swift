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

    // MARK: what the pass costs, against the one already sitting beside it

    /// The MEDIAN of five runs with its spread. One reading is not a yardstick: measured on this Mac
    /// 2026-09-19, the whole live-store pass came out 644.9 ms and then 1184.9 ms on IDENTICAL code, and
    /// the prospect fetch inside it read 182.7, 242.0 and 447.1 ms across three runs of the same bytes.
    /// A difference smaller than that is not visible to any single reading (L224, L395, L656).
    private func medianMilliseconds(_ work: () -> Void) -> (median: Double, low: Double, high: Double) {
        var runs: [Double] = []
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            work()
            runs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        runs.sort()
        return (runs[runs.count / 2], runs[0], runs[runs.count - 1])
    }

    // `QueueModel.scope` now builds this table on every queue rebuild, over the whole corpus, so what it
    // costs is a fair question and "it is only string folding" is not an answer (L353).
    //
    // Judged against `ContradictedCancellation.contradictedKeys`, which is the whole-corpus pass built
    // immediately beside it in the same function, rather than against a fixed millisecond count. A fixed
    // number measures whatever else this Mac is running; a ratio against a neighbour measured in the SAME
    // run does not, because both arms pay the same load (L224). The neighbour is also the right one on
    // the merits: it is the pass this repository already accepted the cost of for the same population.
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theGroupingCostsNoMoreThanThePassBesideIt() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "showlink-cost")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                return
            }
            let ctx = ModelContext(try container(at: clone))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())

            // Mapping the rows is part of what the scope builder pays, so it is inside the measured work
            // rather than hoisted out of it, which would measure a cheaper thing than the app runs.
            let mine = medianMilliseconds { _ = ShowLink.group(all.map(ShowLink.Row.init)) }
            let neighbour = medianMilliseconds { _ = ContradictedCancellation.contradictedKeys(among: all) }

            print("""
            ShowLink pass cost, over \(all.count) rows
              ShowLink.group                  \(String(format: "%.1f", mine.median)) ms             (\(String(format: "%.1f", mine.low)) to \(String(format: "%.1f", mine.high)))
              ContradictedCancellation beside it \(String(format: "%.1f", neighbour.median)) ms             (\(String(format: "%.1f", neighbour.low)) to \(String(format: "%.1f", neighbour.high)))
            """)

            // Three times the neighbour, not one times it, and the ceiling is deliberately far above the
            // reading rather than just over it, so crossing it is a change in kind and not noise (L172).
            #expect(mine.median < neighbour.median * 3,
                    Comment(rawValue: "the grouping costs \(String(format: "%.1f", mine.median)) ms "
                            + "against \(String(format: "%.1f", neighbour.median)) ms for the pass built "
                            + "beside it over the same rows"))

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
