import Foundation
import SwiftData

// Ingests the classify + drafter workflow's results (#112, v3 #420 C3/C4, per-recipient suggestion
// #653). Joins each result by (naturalKey, recipientId) -> Prospect -> the specific Recipient, writing
// that contact's NON-BINDING intent hint, the AI-drafted reply (replyDraftSubject/replyDraftBody, C0
// fields), and its OWN conversation-state suggestion -- based on its own reply, never averaged or
// compromised with a sibling recipient's. A result with no recipientId (legacy v1/v2) carries no
// per-contact target, so it gets no hint, draft, or suggestion at all. NOTHING here sets a binding
// RecipientResolution (decision f); the binding marks are Dan's manual B2 controls. Never overwrites a
// state Dan set on that recipient by hand (#60).
enum ReplyClassifyImporter {
    struct Outcome: Equatable, Sendable {
        var matched = 0
        var suggested = 0
        var skippedManual = 0          // matched but Dan had set that recipient's state by hand
        var skippedEdited = 0          // draft left untouched because Dan had hand-edited the reply (#462)
        var unmatchedKeys: [String] = []
        // #499: set when a context.save() failed, so this run's hints/drafts may not persist.
        var saveFailed = false
    }

    @MainActor
    @discardableResult
    static func ingest(_ results: ReplyClassifyResults, into context: ModelContext) -> Outcome {
        var outcome = Outcome()
        // Group by show so two contacts on one performance are handled together (the v2/v3 fix for the
        // old naturalKey-only last-wins clobber).
        let byKey = Dictionary(grouping: results.results, by: { $0.naturalKey })
        for (key, group) in byKey {
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            guard let p = (try? context.fetch(descriptor))?.first else {
                outcome.unmatchedKeys.append(key)
                continue
            }
            outcome.matched += group.count
            // Per-recipient (C3/#653): write the non-binding intent hint, the AI draft, and the
            // conversation-state suggestion onto the specific contact the reply came from. A result
            // with no recipientId carries no per-contact target (v1/v2), so it's skipped entirely.
            for r in group {
                guard let rid = r.recipientId else { continue }
                p.updateRecipient(id: rid) { rec in
                    rec.intentHint = r.intent   // non-binding hint, always the latest read
                    // Never clobber a reply Dan hand-edited (#462): his unsent text wins until he sends
                    // or dismisses it, mirroring the cold path (PrepImporter draftEditedByDan). Guard on
                    // actual edited TEXT, not the marker alone, so a draft he already sent in Gmail
                    // (body cleared, marker still set) still takes a fresh draft for a genuinely new reply.
                    if rec.replyDraftEditedByDan, rec.replyDraftBody?.isEmpty == false {
                        outcome.skippedEdited += 1
                    } else {
                        if let s = r.draftSubject { rec.replyDraftSubject = s }
                        // A fresh AI draft is not Dan's edit, so clear any stale "edited" marker:
                        // otherwise this AI body would be wrongly protected on the next run.
                        if let b = r.draftBody { rec.replyDraftBody = b; rec.replyDraftEditedByDan = false }
                    }
                    // #653: this recipient's OWN conversation-state suggestion, based on its OWN reply.
                    // suggestConversationState already no-ops if Dan set this recipient's state by hand.
                    guard let intent = r.replyIntent else { return }
                    if rec.conversationStateSource == .manual {
                        outcome.skippedManual += 1
                    } else {
                        rec.suggestConversationState(intent.conversationState, now: Date())
                        outcome.suggested += 1
                    }
                }
            }
        }
        do {
            try context.save()
        } catch {
            outcome.saveFailed = true
        }
        return outcome
    }

    @MainActor
    static func ingestFile(at url: URL, into context: ModelContext) throws -> Outcome {
        let data = try Data(contentsOf: url)
        return ingest(try ReplyClassifyResultsDecoder.decode(data), into: context)
    }

    static var defaultURL: URL { ReplyClassifyResultsDecoder.defaultURL }
}
