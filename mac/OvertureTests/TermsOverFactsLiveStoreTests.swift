import Testing
import Foundation
import SwiftData

// #4357 (plan v7 Phase 3 step 3, oracle part two on real data): every ported queue term, over a clone of
// Dan's live store and over its fourfold copy, answers the same over the live models as over the same rows
// extracted to `RowFacts`. A LIVE STORE TEST, so it gates every merge, as the plan asks.
//
// WHY REAL DATA AS WELL AS THE FIXTURES. A fixture only holds the field shapes its author thought of, and an
// extraction fault is exactly a field shape nobody thought of: a nil where a fixture always sets a value, a
// dropped night entry in its self describing form, a scout title that differs from the display one. The
// clone holds every shape the app has actually written, and the 4x copy holds them at the size the plan
// budgets for.
//
// UNLIKE `FeedBreakEventLiveStoreTests`, THIS ASSERTS. That suite reports because a venue's website changing
// must not block a merge (L68). Nothing in the DATA can make the two arms here disagree: they read the same
// rows through the same term code, so a difference is always a fault in the code between a model and its
// value, and it should stop a merge. The findings name a term, a field and a row's identifier, never a title.
//
// SKIPPED, never red, on a machine with no live store (L411), through the one shared presence check.
@MainActor
@Suite("Every ported queue term answers the same over facts as over models on the live store (#4357)")
final class TermsOverFactsLiveStoreTests {
    private let sandboxes = TemporarySandboxes()

    @Test(.enabled(if: LiveStorePresence.exists, LiveStorePresence.absenceReason))
    func theCloneAndItsFourfoldCopyAnswerTheSameOverFactsAsOverModels() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try sandboxes.make(named: "terms-over-facts")
            guard let base = try LiveStoreClone.makeClone(in: dir) else {
                throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
            }
            let corpora = [("live clone", base), ("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir))]
            let asOf = EasternDate.today(Date())
            for (label, url) in corpora {
                let container = try Phase0.openContainer(at: url)
                let models = try ModelContext(container).fetch(FetchDescriptor<Prospect>())
                // An empty read is a failed open, never a clean bill of health (L98).
                #expect(!models.isEmpty, "the \(label) holds no shows, so nothing below compared anything")
                let drawn = Set(QueueModel.queueScope(models).map(\.naturalKey))
                let started = Phase0.now()
                let findings = TermsOverFacts.findings(models, asOf: asOf, drawn: drawn,
                                                     rowByRow: label == "live clone")
                let flagged = models.filter(\.disappearedFromFeed).count
                print("terms over facts, \(label): \(models.count) row(s), \(flagged) flagged, "
                      + "\(drawn.count) drawn, \(findings.count) finding(s), "
                      + String(format: "%.0f ms", Phase0.ms(since: started)))
                #expect(findings.isEmpty, Comment(rawValue: "\(label):\n" + findings.prefix(20).joined(separator: "\n")))
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
