import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 2, oracle part one): TEMPORARY. The model only T4 projection and T5 boundary as
// they stood on origin/main bcd0f3ce, copied verbatim, run against the new generic ones over ONE frozen
// snapshot of the live clone and its fourfold copy, both arms over the same fetched rows. Its output is
// pasted into the PR, and then this file is deleted in the same PR (L613): nothing old is retained.
@MainActor
@Suite("Oracle part one for T4 and T5: the model only producer and ledger terms against the generic ones (#4357, temporary)")
final class OldAgainstNewProducerLedgerTermsTests {
    private let sandboxes = TemporarySandboxes()

    // MARK: the old terms, verbatim from bcd0f3ce bar their names and their comments
    // (QueueView+Model.swift:3343 and :3867).

    enum ModelOnly {
        // `QueueModel.scope`'s own projection, and `QueueView.producerTables`'s, which was the same line.
        static func shows(_ rows: [Prospect]) -> [ProducerGate.Show] {
            rows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) }
        }

        static func inheritedAnswers(_ answers: [OrgReachabilityAnswer], corpus: [Prospect],
                                     overrides: ProducerOverrides,
                                     refusals: ContactRefusal.Ledger,
                                     heldKeys: Set<String>,
                                     now: Date,
                                     producerCorpus: ProducerGate.Corpus? = nil)
            -> [String: OrgAnswerLedger.Inherited] {
            guard !answers.isEmpty else { return [:] }
            let flat = answers.compactMap { row -> OrgAnswerLedger.Answer? in
                guard let result = row.result else { return nil }
                return OrgAnswerLedger.Answer(orgKey: row.orgKey, result: result, probedAt: row.probedAt,
                                              presenterName: row.presenterName, emails: row.foundEmails)
            }
            let usable = refusals.allowedAnswers(flat)
            let shows = corpus.map {
                OrgAnswerLedger.Show(key: $0.naturalKey, presenter: $0.presenter, venue: $0.venue,
                                     hasOwnAnswer: $0.reachabilityProbedAt != nil)
            }
            return OrgAnswerLedger.inherited(from: usable, shows: shows, now: now, heldKeys: heldKeys,
                                             overrides: overrides, corpus: producerCorpus)
        }
    }

    // MARK: the comparison

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theGenericTermsAnswerAsTheModelOnlyOnesDidOnOneFrozenSnapshot() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "old-against-new-t4-t5")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            for (label, url) in corpora {
                let context = ModelContext(try Phase0.openContainer(at: url))
                let rows = try context.fetch(FetchDescriptor<Prospect>())
                let answers = try context.fetch(FetchDescriptor<OrgReachabilityAnswer>())
                let overrides = ProducerOverrideEditing.overrides(in: context)
                let refusals = ContactRefusal.ledger(in: context)
                #expect(!rows.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                let pidByKey = Dictionary(rows.map { ($0.naturalKey, String(describing: $0.persistentModelID)) },
                                          uniquingKeysWith: { first, _ in first })
                let pid: (String) -> String = { pidByKey[$0] ?? "?" }
                var diff: [String] = []

                // T4: the projection, the two tables and the memo key.
                let oldShows = ModelOnly.shows(rows)
                let newShows = rows.map(ProducerGate.Show.init)
                for (row, (a, b)) in zip(rows, zip(oldShows, newShows)) where a != b {
                    diff.append("ProducerGate.Show differs for row \(pid(row.naturalKey))")
                }
                let oldTables = QueueModel.ProducerTables(shows: oldShows, overrides: overrides)
                let newTables = QueueModel.ProducerTables(shows: newShows, overrides: overrides)
                diff += TermsOverFacts.tableFindings(oldTables, newTables, rows: rows, term: "ProducerTables", pid: pid)
                if oldTables.corpus != newTables.corpus { diff.append("ProducerTables.corpus differs as a value") }
                if oldTables.venueBrands != newTables.venueBrands { diff.append("ProducerTables.venueBrands differs as a value") }
                if QueueModel.ProducerTables.key(shows: oldShows, overrides: overrides)
                    != QueueModel.ProducerTables.key(shows: newShows, overrides: overrides) {
                    diff.append("ProducerTables.key differs")
                }

                // T5: at today's clock, and at the newest answer's instant, so answers that have aged out
                // by today still reach the fan-out and the comparison is not two empty tables (L159).
                let instants = [("today", Date()), ("newest answer", answers.map(\.probedAt).max() ?? Date())]
                var inheritedCounts: [String] = []
                for (when, now) in instants {
                    let old = ModelOnly.inheritedAnswers(answers, corpus: rows, overrides: overrides,
                                                         refusals: refusals, heldKeys: [], now: now,
                                                         producerCorpus: oldTables.corpus)
                    let new = QueueModel.inheritedAnswers(answers, corpus: rows, overrides: overrides,
                                                          refusals: refusals, heldKeys: [], now: now,
                                                          producerCorpus: newTables.corpus)
                    diff += TermsOverFacts.inheritedFindings(old, new, term: "inherited at \(when)", pid: pid)
                    inheritedCounts.append("\(old.count) inherited at \(when)")
                }

                // Decision 5 (generic over models): the generic forms over models cost no more than the old.
                let now = instants[1].1
                let oldT4 = Phase0.median5 { _ = ModelOnly.shows(rows) }
                let newT4 = Phase0.median5 { _ = rows.map(ProducerGate.Show.init) }
                let oldT5 = Phase0.median5 {
                    _ = ModelOnly.inheritedAnswers(answers, corpus: rows, overrides: overrides, refusals: refusals,
                                                   heldKeys: [], now: now, producerCorpus: oldTables.corpus)
                }
                let newT5 = Phase0.median5 {
                    _ = QueueModel.inheritedAnswers(answers, corpus: rows, overrides: overrides, refusals: refusals,
                                                    heldKeys: [], now: now, producerCorpus: newTables.corpus)
                }

                print("old against new, \(label): \(rows.count) row(s), \(answers.count) answer(s), "
                      + "\(inheritedCounts.joined(separator: ", ")), \(diff.count) difference(s)")
                print("old against new, \(label): projection old \(oldT4.text), new \(newT4.text); "
                      + "inheritedAnswers old \(oldT5.text), new \(newT5.text); load \(Phase0.load())")
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
