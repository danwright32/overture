import Foundation
import SwiftData

// Ingests the classify + drafter workflow's results (#112, v3 #420 C3/C4). Joins each result by
// (naturalKey, recipientId) -> Prospect -> the specific Recipient, writing that contact's NON-BINDING
// intent hint and the AI-drafted reply (replyDraftSubject/replyDraftBody, C0 fields). It ALSO keeps the
// single lead conversation state as a non-binding suggestion during the A3 bridge (Phases A-E): once
// per show, preferring an active intent over a decline so a mixed-intent show isn't pushed to "declined"
// while another contact is still live. NOTHING here sets a binding RecipientResolution (decision f);
// the binding marks are Dan's manual B2 controls. Never overwrites a lead state Dan set by hand (#60).
enum ReplyClassifyImporter {
    struct Outcome: Equatable, Sendable {
        var matched = 0
        var suggested = 0
        var skippedManual = 0          // matched but Dan had set the lead state by hand
        var unmatchedKeys: [String] = []
    }

    @MainActor
    @discardableResult
    static func ingest(_ results: ReplyClassifyResults, into context: ModelContext) -> Outcome {
        var outcome = Outcome()
        // Group by show so two contacts on one performance are handled together (the v2/v3 fix for the
        // old naturalKey-only last-wins clobber), and the lead hint is suggested once per show.
        let byKey = Dictionary(grouping: results.results, by: { $0.naturalKey })
        for (key, group) in byKey {
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            guard let p = (try? context.fetch(descriptor))?.first else {
                outcome.unmatchedKeys.append(key)
                continue
            }
            outcome.matched += group.count
            // Per-recipient (C3): write the non-binding intent hint + the AI draft onto the specific
            // contact the reply came from. A result with no recipientId carries no per-contact target
            // (v1/v2), so only the lead hint below applies.
            for r in group {
                guard let rid = r.recipientId else { continue }
                p.updateRecipient(id: rid) { rec in
                    rec.intentHint = r.intent
                    if let s = r.draftSubject { rec.replyDraftSubject = s }
                    if let b = r.draftBody { rec.replyDraftBody = b }
                }
            }
            // Lead conversation hint (bridge, C4 non-binding): once per show, never over a manual state,
            // preferring an active intent so a single decline can't drive the show conversation closed.
            if p.conversationStateSource == .manual {
                outcome.skippedManual += 1
                continue
            }
            let intents = group.compactMap { $0.replyIntent }
            guard let chosen = intents.first(where: { $0 != .declined }) ?? intents.first else { continue }
            p.suggestConversationState(chosen.conversationState, now: Date())
            outcome.suggested += 1
        }
        try? context.save()
        return outcome
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext) throws -> Outcome {
        let data = try Data(contentsOf: url)
        return ingest(try ReplyClassifyResultsDecoder.decode(data), into: context)
    }

    static var defaultURL: URL { ReplyClassifyResultsDecoder.defaultURL }
}
