import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The three `QueueModel.scope` call sites of T1,
// T4 and T6 as they stood on origin/main 5b368ba9 (QueueView+Model.swift:3335, :3342, :3376, :3394), each
// mapping `[Prospect]` itself, run against the generic entry points that replace them, over ONE frozen
// snapshot of the live clone and its fourfold copy. Its output is pasted into the PR, and then this file is
// deleted in the same PR (L613).
@MainActor
@Suite("Oracle part one for the T1, T4 and T6 call sites: the model mapping against the generic entry points (#4357, temporary)")
final class OldAgainstNewLinkCallSitesTests {
    private let sandboxes = TemporarySandboxes()

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericEntryPointsAnswerAsTheCallSitesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-link-call-sites")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            for (label, url) in corpora {
                let context = ModelContext(try Phase0.openContainer(at: url))
                let rows = try context.fetch(FetchDescriptor<Prospect>())
                let overrides = ProducerOverrideEditing.overrides(in: context)
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                // What the pass builds rows for and links over: the queue's own scope, as `QueueView` hands it.
                let prospects = QueueModel.queueScope(rows)
                let drawn = Set(prospects.map(\.naturalKey))
                let pidByKey = Dictionary(rows.map { ($0.naturalKey, String(describing: $0.persistentModelID)) },
                                          uniquingKeysWith: { first, _ in first })
                let pid: (String) -> String = { pidByKey[$0] ?? "?" }
                var diff: [String] = []

                // MARK: old, verbatim from 5b368ba9 bar the local names.
                let oldLinked = EngagementLink.group(prospects.map(EngagementLink.Row.init))
                let oldTables = QueueModel.ProducerTables(shows: rows.map(ProducerGate.Show.init), overrides: overrides)
                let oldGroups = ShowLink.group(rows.map(ShowLink.Row.init))
                let oldCollapse = ShowLink.collapse(rows.map(ShowLink.Row.init), drawn: drawn)

                // MARK: new.
                let newLinked = EngagementLink.group(among: prospects)
                let newTables = QueueModel.ProducerTables(rows: rows, overrides: overrides)
                let newGroups = ShowLink.group(among: rows)
                let newCollapse = ShowLink.collapse(among: rows, drawn: drawn)

                for key in Set(oldLinked.keys).union(newLinked.keys).sorted() where oldLinked[key] != newLinked[key] {
                    diff.append("EngagementLink.group differs for row \(pid(key))")
                }
                diff += TermsOverFacts.tableFindings(oldTables, newTables, rows: rows, term: "ProducerTables", pid: pid)
                if oldTables.corpus != newTables.corpus { diff.append("ProducerTables.corpus differs as a value") }
                if oldTables.venueBrands != newTables.venueBrands { diff.append("ProducerTables.venueBrands differs as a value") }
                for key in Set(oldGroups.keys).union(newGroups.keys).sorted() where oldGroups[key] != newGroups[key] {
                    diff.append("ShowLink.group differs for row \(pid(key))")
                }
                for key in Set(oldCollapse.fronts.keys).union(newCollapse.fronts.keys).sorted()
                where oldCollapse.fronts[key] != newCollapse.fronts[key] {
                    diff.append("ShowLink.collapse fronts differ for row \(pid(key))")
                }
                for key in oldCollapse.hidden.symmetricDifference(newCollapse.hidden).sorted() {
                    diff.append("ShowLink.collapse hidden differs for row \(pid(key))")
                }

                // Decision 5 (generic over models): the entry points over models cost no more than the call sites.
                let oldT6 = Phase0.median5 { _ = EngagementLink.group(prospects.map(EngagementLink.Row.init)) }
                let newT6 = Phase0.median5 { _ = EngagementLink.group(among: prospects) }
                let oldT1 = Phase0.median5 { _ = ShowLink.group(rows.map(ShowLink.Row.init)) }
                let newT1 = Phase0.median5 { _ = ShowLink.group(among: rows) }

                print("old against new, \(label): \(rows.count) row(s), \(prospects.count) in scope, "
                      + "\(oldLinked.count) linked, \(oldGroups.count) grouped, \(oldCollapse.hidden.count) hidden, "
                      + "\(diff.count) difference(s)")
                print("old against new, \(label): EngagementLink.group old \(oldT6.text), new \(newT6.text); "
                      + "ShowLink.group old \(oldT1.text), new \(newT1.text); load \(Phase0.load())")
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
