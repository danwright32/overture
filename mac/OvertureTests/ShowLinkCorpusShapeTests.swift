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

    // #4021: the two derivations of this shape, checked against each other on ONE clone.
    //
    // `scripts/derive-showlink-shape.sh` is the answer anybody can take without a build, and this suite is
    // the shipped rule. They disagree, the reasons are known, and until now those reasons lived in the
    // script's header as prose, which is enforced by nothing (L407). Measured 2026-09-19: the queue agreed
    // exactly while the store did not, 16 against 19, and both differences are the script's own blind
    // spots. The figures get quoted into issue and PR bodies, so the failure this prevents is a number
    // carried forward from the wrong one of the two long after the reason they differ has changed.
    //
    // WHAT IT ASSERTS, and why it is not a count. Comparing two totals says only that they differ and
    // never where, so this compares MEMBERSHIP: every group the shipped rule finds that the script does
    // not must contain at least one row from one of the two populations the script cannot see. That is the
    // header's claim, turned into a check that fails when the gap stops being explainable.
    //
    //   1. `ShowLink` recomputes the fold from each row's CURRENT scout-anchored fields, while the script
    //      reads the fold as it was STORED in `ZNATURALKEY` when the row was last written.
    //   2. `ShowLink` unions Dan's DROPPED nights into the night set, and no SQL expression can decode an
    //      NSKeyedArchiver blob.
    //
    // The script is run with `--dates`, which is the only mode that prints per-member natural keys, and
    // those keys ARE `ShowLink.Row.id`. A run that could not measure is its own outcome and fails loudly
    // rather than reading as agreement (L98).
    @Test(.enabled(if: liveStoreExists, "no live store on this machine"))
    func theScriptAndTheShippedRuleAgreeOrTheDifferenceIsExplainedByAKnownBlindSpot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "showlink-two-derivations")
            guard let clone = try LiveStoreClone.makeClone(in: dir) else {
                await RealStoreTestLock.shared.release()
                return
            }
            let ctx = ModelContext(try container(at: clone))
            let all = try ctx.fetch(FetchDescriptor<Prospect>())
            let rows = all.map(ShowLink.Row.init)
            let shipped = ShowLink.group(rows)

            let script = try Self.runShapeScript(store: clone, asOf: QueueModel.easternToday())
            #expect(!script.isEmpty,
                    "the script produced no group membership at all, so nothing below compared anything")

            // The rows the script cannot see correctly, DERIVED from the difference itself rather than
            // from a list of fields somebody thought of. The first draft of this check listed
            // `scoutVenue != venue` and dropped nights, and it missed a real pair on the first run
            // (`macmccarty + kiddtwist` against `macmccarty +kiddtwist` at Jalopy Theatre) because that
            // row's drift is in the TITLE. The header's claim is about the FOLD, not about two named
            // fields, so this asks the fold: any row whose recomputed title or venue differs from the
            // one stored in its own key is a row the script reads differently, whichever field moved.
            let blindSpots = Set(all.filter { row in
                let stored = row.naturalKey.split(separator: "|", omittingEmptySubsequences: false)
                guard stored.count >= 3 else { return true }   // unreadable key: the script drops it too
                let storedTitle = String(stored[0])
                let storedVenue = stored[2...].joined(separator: "|")
                let live = ShowLink.Row(row)
                return ShowLink.foldedTitle(live.groupName) != storedTitle
                    || ShowLink.foldedVenue(live.venue) != storedVenue
                    || !DroppedNight.all(on: row).isEmpty
            }.map(\.naturalKey))

            let shippedGroups = Set(shipped.map { Set([$0.key] + $0.value) })
            let unexplained = shippedGroups.filter { group in
                !script.contains(group) && group.isDisjoint(with: blindSpots)
            }

            print("Two derivations of the grouping shape, same clone: shipped rule "
                  + "\(shippedGroups.count) group(s), script \(script.count) group(s), "
                  + "\(blindSpots.count) row(s) in a known blind spot, "
                  + "\(unexplained.count) difference(s) the blind spots do not explain")

            #expect(unexplained.isEmpty,
                    """
                    the shipped rule finds \(unexplained.count) group(s) the script misses for no reason \
                    the script's header accounts for, so the reconciliation written there is stale: \
                    \(unexplained.map { $0.sorted() }.prefix(3))
                    """)

            try? FileManager.default.removeItem(at: clone)
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    /// Every group the script reports, as sets of natural keys. Throws rather than returning empty when
    /// the command could not run: an empty answer and a failed run are different facts (L215).
    nonisolated private static func runShapeScript(store: URL, asOf: String) throws -> Set<Set<String>> {
        let script = RepoRoot.url.appendingPathComponent("scripts/derive-showlink-shape.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--store", store.path, "--asof", asOf, "--dates"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShapeScriptRefusal.exited(Int(process.terminationStatus))
        }
        let text = String(decoding: data, as: UTF8.self)
        var groups: Set<Set<String>> = []
        var current: Set<String> = []
        var inDates = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("dates=") { inDates = true; continue }
            guard inDates else { continue }
            if let range = line.range(of: "  key ") {
                current.insert(String(line[range.upperBound...]))
            } else if line.hasPrefix("  [") {
                if current.count > 1 { groups.insert(current) }
                current = []
            }
        }
        if current.count > 1 { groups.insert(current) }
        return groups
    }

    enum ShapeScriptRefusal: Error, CustomStringConvertible {
        case exited(Int)
        var description: String {
            switch self {
            case .exited(let code):
                return "derive-showlink-shape.sh exited \(code), so the two derivations were never "
                    + "compared. 2 is UNMEASURED and 3 is no store; neither is agreement (#4021)."
            }
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
