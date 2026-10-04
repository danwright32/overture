import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The long tail terms slice H ports, as their model
// only bodies stood on origin/main b4cfd01c (QueueView+Model.swift's `queueScope` and the three tables inline in
// `scope`, QueueRenderPass.swift's unseen survivors and `fanOutWarning`, Prospect.swift's `isClosed`), copied
// verbatim bar being written as functions, run against the ported terms over ONE frozen snapshot of the live
// clone and its fourfold copy. Its output is pasted into the PR, and then this file is deleted in the same PR.
@MainActor
@Suite("Oracle part one for slice H: the model only long tail against the ported one (#4357, temporary)")
final class OldAgainstNewLongTailTests {
    private let sandboxes = TemporarySandboxes()

    enum Old {
        static func queueScope(_ all: [Prospect]) -> [Prospect] {
            all.enumerated()
                .filter { $0.element.statusRaw != "dismissed" }
                .sorted { lhs, rhs in
                    for descriptor in QueueModel.queueScopeOrder {
                        switch descriptor.compare(lhs.element, rhs.element) {
                        case .orderedAscending: return true
                        case .orderedDescending: return false
                        case .orderedSame: continue
                        }
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        }

        static func titlesByKey(_ corpus: [Prospect]) -> [String: String] {
            Dictionary(corpus.map { ($0.naturalKey, $0.groupName) }, uniquingKeysWith: { first, _ in first })
        }

        static func laterLookalikes(_ corpus: [Prospect]) -> [String: [String]] {
            var laterLookalikesByKey: [String: [Prospect]] = [:]
            for row in corpus {
                guard let target = row.arrivedLookingLike else { continue }
                laterLookalikesByKey[target, default: []].append(row)
            }
            return laterLookalikesByKey.mapValues { rows in
                rows.sorted {
                    let (left, right) = ($0.firstSeenAt ?? .distantPast, $1.firstSeenAt ?? .distantPast)
                    return left != right ? left > right : $0.naturalKey < $1.naturalKey
                }.map(\.naturalKey)
            }
        }

        static func nightsByKey(_ corpus: [Prospect]) -> [String: String] {
            Dictionary(
                corpus.compactMap { row -> (String, String)? in
                    guard let night = row.performanceDate, !night.isEmpty else { return nil }
                    return (row.naturalKey, night)
                },
                uniquingKeysWith: { first, _ in first })
        }

        static func isClosed(_ p: Prospect) -> Bool {
            if p.orgDoNotContact { return true }
            switch p.performanceStatus {
            case .booked: return true
            case .lostDoorOpen, .lostNotInterested, .stoodDown, .active, .new:
                return p.performanceStatus.endedWithoutAShoot || p.outcome == .lostSoft || p.outcome == .lostHard
            }
        }

        static func unseenSurvivors(_ everyProspect: [Prospect], today: String) -> [String] {
            everyProspect
                .filter { p in
                    guard p.mergeSurvivorUnseenAt != nil, !isClosed(p) else { return false }
                    return EasternDate.runIsLive(
                        lastNight: EasternDate.runLastNight(runEndDate: p.runEndDate,
                                                            performanceDate: p.performanceDate),
                        today: today)
                }
                .map(\.naturalKey)
        }

        static func fanOutWarning(_ prospects: [Prospect]) -> String? {
            PossibleMatchFanOut.warningLine(
                PossibleMatchFanOut.findings(rows: prospects.compactMap { p in
                    p.possibleMatchName.map { (act: p.groupName, match: $0) }
                }))
        }
    }

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func thePortedLongTailAnswersAsTheModelOnlyOneDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-long-tail")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            for (label, url) in corpora {
                let rows = try ModelContext(try Phase0.openContainer(at: url)).fetch(FetchDescriptor<Prospect>())
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                var diff: [String] = []
                if Old.queueScope(rows).map(\.persistentModelID) != QueueModel.queueScope(rows).map(\.persistentModelID) {
                    diff.append("queueScope differs")
                }
                if Old.titlesByKey(rows) != QueueModel.titlesByKey(among: rows) { diff.append("titlesByKey differs") }
                if Old.laterLookalikes(rows) != QueueModel.laterLookalikes(among: rows) { diff.append("laterLookalikes differs") }
                if Old.nightsByKey(rows) != QueueModel.nightsByKey(among: rows) { diff.append("nightsByKey differs") }
                if Old.fanOutWarning(rows) != QueueRenderPass.fanOutWarning(rows) { diff.append("fanOutWarning differs") }
                var closedCount = 0, survivorCounts: [Int] = []
                for p in rows {
                    if Old.isClosed(p) != p.isClosed { diff.append("isClosed differs for row \(p.persistentModelID)") }
                    if Old.isClosed(p) { closedCount += 1 }
                }
                // Today, and four months back, so survivors that have since played are judged while still ahead.
                for day in [EasternDate.today(Date()), EasternDate.today(Date().addingTimeInterval(-120 * 86_400))] {
                    let old = Old.unseenSurvivors(rows, today: day)
                    if old != QueueRenderPass.unseenSurvivors(among: rows, today: day) {
                        diff.append("unseenSurvivors differs on \(day)")
                    }
                    survivorCounts.append(old.count)
                }
                let lookalikeTargets = Old.laterLookalikes(rows).count
                let scoped = Old.queueScope(rows).count
                print("old against new, \(label): \(rows.count) row(s), \(diff.count) difference(s)")
                print("old against new, \(label): \(scoped) in scope, \(lookalikeTargets) lookalike target(s), "
                      + "\(Old.nightsByKey(rows).count) dated, \(closedCount) closed, unseen survivors \(survivorCounts), "
                      + "fan out line \(Old.fanOutWarning(rows) == nil ? "absent" : "present")")
                for line in diff.prefix(20) { print("old against new, \(label): " + line) }
                #expect(diff.isEmpty, Comment(rawValue: diff.prefix(20).joined(separator: "\n")))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
