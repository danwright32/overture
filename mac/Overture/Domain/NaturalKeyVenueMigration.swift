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
            //
            // #1780: what blocks a merge is an outreach RECORD, not a dismissal. Two rows Dan merely
            // refused used to deadlock here forever with nothing on screen to say so. Measured on the live
            // store 2026-07-29: "Bone Wars" on 2026-07-26 sat twice, both dismissed "too soon", nothing
            // sent or drafted on either, so there was never anything to reconcile.
            let withHistory = members.filter(hasOutreachHistory)
            if mustDefer(members) {
                // Genuine conflict. Never merge outreach history blind: leave every row untouched.
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                NSLog("#1064/#1780 NaturalKeyVenueMigration: %d prospects carrying history, %d distinct dismissal reasons, fold to one key; leaving them untouched for Dan to reconcile.",
                      withHistory.count, Set(members.compactMap(\.dismissReasonRaw)).count)
                // copy-inventory:ignore-end
                summary.conflictsDeferred += 1
                continue
            }

            // At most one row carries history. It (or, if all are pristine, the most recently SEEN row)
            // survives and takes the folded key; every other row here is provably empty, so deleting it
            // drops no outreach record. Delete the losers FIRST, then assign the survivor's key, so the
            // UNIQUE index is never asked to hold two rows on the same key even transiently.
            //
            // LIVE-STORE-CLAIM verified=2026-07-28 measure="the duplicate pairs a parenthetical venue split, and which row of each carries the current client match"
            // #1686: which pristine row survives is not a coin toss, because the two disagree. A row is
            // re-matched and re-scored only when a sweep finds it BY KEY, so the row whose key split
            // stopped being found and still carries whatever the rules said the day it was ingested. On
            // the live store that row reads "no prior relationship, score 7" from two days before #1216
            // taught the matcher to read the presenter field, while its twin reads "booked, score 27"
            // against a real Downbeat client. `ingestedAt` is rewritten on every re-scout, so it means
            // LAST SEEN, and keeping the earliest kept exactly the stale row: one card, saying he has
            // never worked with a group he has. The freshest wins instead.
            // #1780: a DISMISSED row outranks a pristine one when neither carries an outreach record.
            // Without this the freshest row wins, and where the freshest is an untouched re-scout of a
            // show Dan has already refused, the merge would quietly put it back in front of him, which is
            // the opposite of what this pass is for.
            let freshest: (Prospect, Prospect) -> Bool = { $0.ingestedAt < $1.ingestedAt }
            let refused: [Prospect] = members.filter { $0.status == .dismissed }
            let survivor: Prospect = withHistory.first
                ?? refused.max(by: freshest)
                ?? members.max(by: freshest)!
            // The show was first seen when the EARLIEST of these rows first saw it. Carried across before
            // the losers go, or the merge would silently move the funnel's opening node (#16) forward to
            // whenever the duplicate happened to appear.
            let firstSightings = members.compactMap(\.firstSeenAt)
            if let earliest = firstSightings.min(),
               survivor.firstSeenAt == nil || earliest < survivor.firstSeenAt! {
                survivor.firstSeenAt = earliest
            }
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

    // #1780: the deferral decision, named once. Anything that predicts what this pass will do (the
    // live-store rehearsal in ParentheticalVenueMergeLiveStoreTests) asks THIS rather than keeping a
    // second copy of the rule, because a prediction written beside the rule drifts from it silently and
    // then reports a fix as a regression.
    //
    // Defer when two or more rows carry history, EXCEPT in the one narrow case this issue measured: every
    // row in the collision carries nothing beyond a dismissal, and they all give the same reason. Both
    // halves of that exception are load-bearing. If any row was actually contacted the old refusal stands
    // whole, because a dismissal on its twin may record how that outreach ended. And two refusals that
    // disagree are a real conflict, since choosing between them silently rewrites why Dan said no, which
    // the outcome reporting reads.
    static func mustDefer(_ members: [Prospect]) -> Bool {
        guard members.count > 1 else { return false }
        guard members.filter(hasOutreachHistory).count >= 2 else { return false }
        let neverContacted = members.allSatisfy { !hasRecordBeyondADismissal($0) }
        let reasons = Set(members.compactMap(\.dismissReasonRaw))
        return !(neverContacted && reasons.count <= 1)
    }

    // A row is a pristine duplicate (safe to drop in a merge) ONLY when it is brand new and carries no
    // send, draft, recipient, dismissal, non-default outcome, or Dan decision. Anything else counts as
    // history and must never be deleted, and forces a colliding pair into the deferred branch above.
    static func hasOutreachHistory(_ p: Prospect) -> Bool {
        if p.status != .new { return true }
        if p.dismissReasonRaw != nil { return true }
        return hasRecordBeyondADismissal(p)
    }

    // #1780: the narrower question the MERGE needs, split out of the predicate above rather than copied
    // beside it, so the two can never disagree about what counts.
    //
    // `hasOutreachHistory` asks "has ANYTHING happened to this row", which is the right question for its
    // three other callers (SameNightTitleVariantMerge, DriftedRunMerge, ScoutService). It is too broad for
    // deciding a deferral: a bare dismissal satisfied it, so any two dismissed duplicates went to the
    // deferred branch and stayed there permanently, reported only through NSLog, which is invisible from a
    // running Overture. A dismissal is a DECISION, recoverable and carried onto the survivor below; an
    // outreach record is a fact about the outside world and must never be destroyed.
    static func hasRecordBeyondADismissal(_ p: Prospect) -> Bool {
        if p.sentAt != nil || p.gmailThreadId != nil || p.gmailMessageId != nil { return true }
        if p.draftBody != nil || p.draftSubject != nil { return true }
        if !p.recipients.isEmpty { return true }
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
