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

    // #2499: the field this pass moves, declared HERE so `KeyRealignment.coverage` is assembled from
    // each pass's own statement rather than restating it. It shipped before that guard existed, so it
    // was covered in FACT and not by the check, which is the same as being uncovered the day somebody
    // changes the fold and looks at the list.
    static let realigns: [KeyRealignment.Field] = [
        KeyRealignment.Field(model: "Prospect", property: "naturalKey",
                             pass: "NaturalKeyVenueMigration", tableClass: .answer)
    ]

    struct Summary: Equatable {
        var rekeyed = 0            // rows given a new folded key (no merge)
        var duplicatesDeleted = 0  // provably-empty duplicate rows removed by a safe merge
        var conflictsDeferred = 0  // colliding groups left untouched because more than one carried history
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var summary = Summary()
        // #1606: every rename this pass makes, recorded so work already in flight can still find the row
        // it was about. A paid check's marker and its results file both hold the OLD key, and without this
        // the settle's intersection matched nothing: the answer was lost, the show read as unchecked, and
        // Dan paid again. Silent by construction, since nothing reports a settle that matched zero rows.
        var renames: [(from: String, to: String)] = []

        // Group every row by the key it WOULD have under the new normalization. Two rows share a group
        // exactly when they now fold to the same natural key.
        // #1886: the key each row SHOULD carry is anchored to the scout's own values, never to what the
        // card displays. Computing it from the display fields here undid, one launch later, both features
        // that rewrite a display field precisely so the key can stay put (#1274's rename, #1846's merged
        // room name): the row came back holding Dan's spelling, and the next scout, arriving with the
        // listing's spelling, computed a key that matched nothing and inserted a second card.
        var groups: [String: [Prospect]] = [:]
        for p in prospects {
            groups[p.scoutAnchoredNaturalKey, default: []].append(p)
        }

        for (newKey, members) in groups {
            if members.count == 1 {
                let only = members[0]
                if only.naturalKey != newKey {
                    renames.append((from: only.naturalKey, to: newKey))
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
                // #1689: a NOTE. The migration is working exactly as designed, refusing to merge rows
                // that carry outreach history, and it says the same thing about the same rows on every
                // launch until Dan reconciles them (#1639). None of that is a problem to raise.
                AgentLog.note("#1064/#1780 NaturalKeyVenueMigration: \(withHistory.count) prospects carrying history, \(Set(members.compactMap(\.showOutcomeRaw)).count) distinct dismissal reasons, fold to one key; leaving them untouched for Dan to reconcile.")
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
            // RETIRED, kept because the reasoning is what #2001 overturned and a reader meeting only the
            // new rule would not know it was ever weighed. #1780 made a DISMISSED row outrank a pristine
            // one when neither carried an outreach record, on the grounds that otherwise the freshest wins
            // and an untouched re-scout of a show Dan had refused would quietly put it back in front of
            // him. He asked for exactly that outcome in #2001, deliberately: see below.
            // #1845/#2001: the same ladder the two merge passes use, spelled through the same named rungs,
            // with this pass's own tie-break (freshest, for the reason above). The first rung is the narrow
            // question rather than `withHistory.first`, so a merely-FOUND address no longer decides a
            // survivor in fetch order.
            //
            // #2001 REPLACES the "a dismissed row outranks a pristine one" rung recorded above. Dan asked
            // for the opposite: when a copy he refused meets one he has not decided about, the undecided
            // copy survives so the show comes back and he can look again, because the refusal may have
            // been made on insufficient information. Where every row carries a decision there is no second
            // look to give, so `preferringASecondLook` returns them all and the freshest refusal wins as
            // it always has.
            let freshest: (Prospect, Prospect) -> Bool = { $0.ingestedAt < $1.ingestedAt }
            let candidates = preferringASecondLook(members)
            let survivor: Prospect =
                members.first(where: { hasRecordBeyondADismissal($0, countingFoundAddresses: false) })
                ?? richestContactList(candidates.sorted { freshest($1, $0) })
                ?? candidates.max(by: freshest)!
            // The show was first seen when the EARLIEST of these rows first saw it. Carried across before
            // the losers go, or the merge would silently move the funnel's opening node (#16) forward to
            // whenever the duplicate happened to appear.
            let firstSightings = members.compactMap(\.firstSeenAt)
            if let earliest = firstSightings.min(),
               survivor.firstSeenAt == nil || earliest < survivor.firstSeenAt! {
                survivor.firstSeenAt = earliest
            }
            // #3124: and his DECISIONS, before the rows holding them go. Same place and same reason as
            // `firstSeenAt` above: whatever only a loser knew is gone the moment it is deleted (L5).
            carryDansDecisions(onto: survivor, from: members)
            for loser in members where loser !== survivor {
                context.delete(loser)
                summary.duplicatesDeleted += 1
            }
            if survivor.naturalKey != newKey {
                renames.append((from: survivor.naturalKey, to: newKey))
                survivor.naturalKey = newKey
                summary.rekeyed += 1
            }
        }

        // Recorded after the pass, so a run that threw partway leaves no claim that a rename happened.
        // A failure to record is not a reason to fail the migration: the rows are already correct, and the
        // cost is the one this protects against (a paid answer that cannot be matched), not corruption.
        try? NaturalKeyRemap.record(renames, at: Date())
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
    // #1845 narrows `neverContacted` by one clause: an address a paid check merely FOUND no longer holds
    // a merge open. Measured on the live store 2026-08-03, that clause alone was wedging three shows into
    // the queue twice at two different ranks (2 against 10), permanently, on nine rows of which not one
    // had ever been sent anything. Everything else about this decision is unchanged, including the
    // refusal to choose between two dismissal reasons that disagree.
    // #3124: a decision of Dan's must not die with whichever duplicate row happened to hold it.
    //
    // The merge does not combine rows field by field. It picks ONE survivor and deletes every other
    // member, and none of the three tests standing between a row and that delete can see a decision that
    // did not move the row's stage. `mustDefer` needs TWO rows carrying history. `hasOutreachHistory`
    // counts a status off `new` and a show outcome. `hasRecordBeyondADismissal`, which actually picks the
    // survivor, asks whether the row reached the OUTSIDE WORLD, and a decision of Dan's is not that. So a
    // row still at `new` whose only content is his rename loses to any fresher pristine duplicate.
    //
    // They are deliberately NOT added to `hasRecordBeyondADismissal`, which would reintroduce #1780: that
    // predicate's other job is deciding a DEFERRAL, and teaching it to answer yes to a rename would make
    // two renamed duplicates defer forever with nothing on screen saying so. #1845 narrowed it again after
    // three shows sat wedged in the queue twice, permanently, on nine rows none of which had been sent
    // anything. Carrying changes WHAT THE SURVIVOR KNOWS and never whether a merge happens, so it cannot
    // deadlock anything.
    //
    // Dan's call, 2026-08-22, on the case where two members each carry a DIFFERENT decision: keep one
    // card and carry both decisions onto it, rather than deferring the merge or dropping one of them.
    //
    // Every field here is one of `ProspectFieldClassificationTests.danDecisionsTheRuleCannotSee`, and a
    // guard there fails if that list grows a field this function does not name, so a new decision cannot
    // arrive without a carry rule (L96).
    static func carryDansDecisions(onto survivor: Prospect, from members: [Prospect]) {
        let losers = members.filter { $0 !== survivor }

        // Kept visible after a genre change. ANY member saying so wins, because `false` is what a row
        // holds for never having been asked: `GenreVisibility` writes this only on the row that was
        // showing when a genre change would have hidden it, so an absent flag is silence, not a refusal.
        if losers.contains(where: { $0.keptVisibleAfterGenreChange }) {
            survivor.keptVisibleAfterGenreChange = true
        }

        // The rename, and the flag and the NAME move together. Carrying the flag alone would leave the
        // survivor claiming Dan renamed it while showing the scout's wording, which is the row asserting
        // the opposite of what happened (L163). `scoutGroupName` is deliberately NOT carried: it mirrors
        // the LATEST scout-emitted name, so the survivor's own is the current one.
        //
        // A survivor that already carries an override keeps it. That is a decision of Dan's too, and
        // ranking his decisions against each other is not this pass's to do. Only an undecided survivor
        // is filled in, and where two losers both carry one the freshest wins, which is this pass's own
        // tie-break rather than a second rule invented here.
        if !survivor.groupNameOverriddenByDan,
           let renamed = losers.filter({ $0.groupNameOverriddenByDan })
               .max(by: { $0.ingestedAt < $1.ingestedAt }) {
            survivor.groupName = renamed.groupName
            survivor.groupNameOverriddenByDan = true
        }
    }

    static func mustDefer(_ members: [Prospect]) -> Bool {
        guard members.count > 1 else { return false }
        guard members.filter(hasOutreachHistory).count >= 2 else { return false }
        let neverContacted = members.allSatisfy {
            !hasRecordBeyondADismissal($0, countingFoundAddresses: false)
        }
        let reasons = Set(members.compactMap(\.showOutcomeRaw))
        return !(neverContacted && reasons.count <= 1)
    }

    // #1845: the copy whose contact list is worth keeping, once a merge may collapse rows that each hold
    // addresses. The loser's addresses go with it and only a fresh paid check would bring them back, so
    // the richest list survives. Nil when no row here holds one. Ties keep the FIRST row given, so the
    // caller's own ordering decides and the answer cannot vary with fetch order.
    static func richestContactList(_ members: [Prospect]) -> Prospect? {
        members.reduce(nil) { best, p in
            guard !p.recipients.isEmpty else { return best }
            guard let best else { return p }
            return p.recipients.count > best.recipients.count ? p : best
        }
    }

    // #1845: the row carrying a decision Dan made about this show, as distinct from anything a scout or a
    // paid check wrote onto it. Named because the survivor ladders in the merge passes need exactly this
    // rung, and spelling it inline in each of them is how the three drift apart.
    static func carriesDansDecision(_ p: Prospect) -> Bool {
        p.status != .new || p.showOutcomeRaw != nil
    }

    // #2001: which rows of a group may survive it, once a copy Dan has refused meets one he has not.
    // The UNDECIDED rows win, so the show returns to the queue and he gets to look again. His words
    // (2026-08-03): "it's not about the contact list, it's that I may have made a decision based on
    // insufficient information. so give me another chance to look at it."
    //
    // This deliberately INVERTS the rule #1780 wrote here, which kept the refused row precisely so an
    // untouched re-scout could not put a refused show back in front of him. He asked for that outcome on
    // purpose, and chose a genuinely clean look over a card that remembers, so the refusal goes with the
    // row it was on and the returning card says nothing about it.
    //
    // A row that reached the OUTSIDE WORLD is not covered by this and must be picked ahead of it by every
    // caller: a refusal is a judgment he may revisit, while a sent email is a fact that cannot be unsent.
    // When every row here carries a decision there is no second look to give, so the whole group stands
    // and each pass falls through to its own tie-break.
    static func preferringASecondLook(_ members: [Prospect]) -> [Prospect] {
        let undecided = members.filter { !carriesDansDecision($0) }
        return undecided.isEmpty ? members : undecided
    }

    // A row is a pristine duplicate (safe to drop in a merge) ONLY when it is brand new and carries no
    // send, draft, recipient, dismissal, non-default outcome, or Dan decision. Anything else counts as
    // history and must never be deleted, and forces a colliding pair into the deferred branch above.
    static func hasOutreachHistory(_ p: Prospect) -> Bool {
        if p.status != .new { return true }
        if p.showOutcomeRaw != nil { return true }
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
    //
    // #1845 adds the one seam this predicate has. `countingFoundAddresses` is the difference between the
    // two questions it is asked: "has anything at all happened here" (true, the default, which is what
    // `hasOutreachHistory` above and every existing caller mean) and "did we reach the outside world"
    // (false, which is what a DEFERRAL means, since a found address can be found again and a sent email
    // cannot be unsent). One list of clauses with one clause parameterised, rather than two lists that
    // drift, for the same reason this function was split out of the one above in the first place.
    // #2717: unaffected by attached conversations, and the reason is the LEVEL (L83). An attach writes the
    // thread on the RECIPIENT and deliberately never touches the Prospect rollup this line reads, so the
    // clause below cannot see one. It would not matter if it could: a show whose form pitch was answered
    // has plainly had something happen on it, which is the question being asked.
    static func hasRecordBeyondADismissal(_ p: Prospect, countingFoundAddresses: Bool = true) -> Bool {
        if p.sentAt != nil || p.gmailThreadId != nil || p.gmailMessageId != nil { return true }
        if p.draftBody != nil || p.draftSubject != nil { return true }
        if countingFoundAddresses ? !p.recipients.isEmpty
                                  : p.recipients.contains(where: \.wasWrittenTo) { return true }
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
