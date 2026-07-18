import Foundation
import SwiftData

// #1064: the venue half of the natural key now folds formatting variance (an embedded street address, a
// comma before a state code, a street-suffix abbreviation, slash spacing) through VenueNormalization, so
// two spellings of ONE physical venue produce ONE key. New extractions compute the folded key
// immediately, but rows ALREADY in the store carry their OLD, unfolded keys, so a fresh scout of a
// differently spelled venue would still not dedupe against an existing row. This one-time, idempotent
// launch pass recomputes each stored prospect's key with the new normalization and reconciles the
// duplicates that fold together.
//
// BLAST RADIUS. This rewrites Prospect.naturalKey (a UNIQUE column) for every stored row whose venue
// carried any of that variance, and it can DELETE rows, in one narrow, provably safe case only. The app
// backs up the whole store on every launch (#601/#602) before migrations run, so a bad pass is
// recoverable, but this is the one migration that can remove a row, so it is deliberately conservative:
//
//   - A row whose folded key is unchanged is left untouched.
//   - A row whose folded key changes and does NOT collide with any other row is simply re-keyed in place.
//   - When two or more rows fold to the SAME key (a real duplicate of one show), they are merged ONLY
//     when at most one of them carries any outreach history or Dan decision. The row with history (or,
//     when all are pristine, the earliest-ingested one) survives and takes the folded key; the other,
//     provably-empty duplicate rows are deleted. Nothing carrying history is ever dropped.
//   - When TWO OR MORE colliding rows EACH carry history, the collision is NOT resolved blind: the rows
//     are left exactly as they are (old keys, all present, still surfaced to Dan) and the conflict is
//     logged. Merging real outreach records is Dan's call, not a migration's (AGENTS.md / memory: anything
//     that changes who was emailed or what was said, he must actively agree to). Because the fold is now
//     live for new keys, a future scout could add a third row for such a deferred pair; that is the
//     documented, deliberately deferred risk, preferred over silently merging two real histories.
//
// Idempotent: after a run every survivor's stored key already equals its folded key, singletons are
// already folded, and a deferred conflict still has two history rows, so a second pass changes nothing
// and deletes nothing.
enum NaturalKeyVenueMigration {
    struct Summary: Equatable {
        var rekeyed = 0            // rows given a new folded key (no merge)
        var duplicatesDeleted = 0  // provably-empty duplicate rows removed by a safe merge
        var conflictsDeferred = 0  // colliding groups left untouched because more than one carried history
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var summary = Summary()

        // Group every row by the key it WOULD have under the new normalization. Two rows share a group
        // exactly when they now fold to the same natural key.
        var groups: [String: [Prospect]] = [:]
        for p in prospects {
            let newKey = Prospect.makeNaturalKey(groupName: p.groupName,
                                                 performanceDate: p.performanceDate,
                                                 venue: p.venue)
            groups[newKey, default: []].append(p)
        }

        for (newKey, members) in groups {
            if members.count == 1 {
                let only = members[0]
                if only.naturalKey != newKey {
                    only.naturalKey = newKey
                    summary.rekeyed += 1
                }
                continue
            }

            // Collision: two or more rows fold to one key.
            let withHistory = members.filter(hasOutreachHistory)
            if withHistory.count >= 2 {
                // Genuine conflict. Never merge outreach history blind: leave every row untouched.
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                NSLog("#1064 NaturalKeyVenueMigration: %d prospects carry outreach history and fold to one key; leaving them untouched for Dan to reconcile.",
                      withHistory.count)
                // copy-inventory:ignore-end
                summary.conflictsDeferred += 1
                continue
            }

            // At most one row carries history. It (or, if all are pristine, the earliest-ingested row)
            // survives and takes the folded key; every other row here is provably empty, so deleting it
            // drops no outreach record. Delete the losers FIRST, then assign the survivor's key, so the
            // UNIQUE index is never asked to hold two rows on the same key even transiently.
            let survivor = withHistory.first ?? members.min(by: { $0.ingestedAt < $1.ingestedAt })!
            for loser in members where loser !== survivor {
                context.delete(loser)
                summary.duplicatesDeleted += 1
            }
            if survivor.naturalKey != newKey {
                survivor.naturalKey = newKey
                summary.rekeyed += 1
            }
        }

        return summary
    }

    // A row is a pristine duplicate (safe to drop in a merge) ONLY when it is brand new and carries no
    // send, draft, recipient, dismissal, non-default outcome, or Dan decision. Anything else counts as
    // history and must never be deleted, and forces a colliding pair into the deferred branch above.
    static func hasOutreachHistory(_ p: Prospect) -> Bool {
        if p.status != .new { return true }
        if p.sentAt != nil || p.gmailThreadId != nil || p.gmailMessageId != nil { return true }
        if p.draftBody != nil || p.draftSubject != nil { return true }
        if !p.recipients.isEmpty { return true }
        if p.dismissReasonRaw != nil { return true }
        if p.outcomeRaw != Outcome.noResponse.rawValue { return true }
        if p.draftEditedByDan || p.recipientsEditedByDan { return true }
        if p.confidenceReviewedByDan || p.classificationOverriddenByDan { return true }
        if p.performerMatchReviewed || p.performerMatchDismissed { return true }
        if p.bookingSuggestionDismissed || p.alreadyCoveredDismissed { return true }
        if p.orgDoNotContact { return true }
        if p.conflictClearedKey != nil { return true }
        if p.reprepDraftRequested || p.reprepContactsRequested { return true }
        return false
    }
}
