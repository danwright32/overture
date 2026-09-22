import Foundation
import SwiftData

// #1559: collapse the duplicate prospect rows #1528 left behind, without hiding a live show.
//
// #1528 stopped NEW duplicates appearing when a run's opening night drifts. The rows already stored could
// not be fixed by it: they all carry the same feed id, so a scout matches an arbitrary one and the rest
// stay. Measured 2026-07-26: 4 groups, 10 rows.
//
// BLAST RADIUS. This DELETES prospect rows, so it is deliberately narrower than it could be, and the
// launch backup (#601/#602) taken just before migrations run is what makes it recoverable.
enum DriftedRunMerge {
    struct Summary: Equatable {
        var duplicatesDeleted = 0
        var conflictsDeferred = 0
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let stored = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var summary = Summary()

        var groups: [String: [Prospect]] = [:]
        for p in stored {
            guard let id = p.seriesId, !id.isEmpty else { continue }   // no id, no group (Wisard)
            groups[id + "|" + canonVenue(p.venue), default: []].append(p)
        }

        // #4055: and the venue's OWN opaque production token, for rows carrying no seriesId at all.
        //
        // #4029 stopped NEW token duplicates being minted, exactly as #1528 did for a drifted run, and it
        // cannot reach the rows already stored because an ingest arm only runs when a night ARRIVES
        // (L389). That is the same gap this pass was created to close, so it is grouped here rather than
        // in a fourth pass with its own survivor rule and its own deferral (L613, L655).
        //
        // Measured on the live store 2026-09-20 over a WAL inclusive clone of 1,275 rows: two pairs, both
        // at The Green Room 42, and `seriesId` is nil on all four rows, which is exactly why the loop
        // above has never seen them.
        //
        // The token and the discard rule come from `ShowLink`, never a copy (L370). The discard matters
        // MORE here than on the display side it was written for: there a wrong join costs a re-render,
        // here it DELETES a row.
        var tokensByRow: [ObjectIdentifier: Set<String>] = [:]
        var seen: [(token: String, title: String, venue: String)] = []
        for p in stored where (p.seriesId ?? "").isEmpty {
            let urls = (p.sourceListingURL.map { [$0] } ?? []) + p.runSourceURLs
            let tokens = Set(urls.compactMap(ProductionToken.inURL))
            guard !tokens.isEmpty else { continue }
            tokensByRow[ObjectIdentifier(p)] = tokens
            let title = ShowLink.foldedTitle(p.groupName)
            let room = ShowLink.foldedVenue(p.venue)
            for token in tokens { seen.append((token: token, title: title, venue: room)) }
        }
        let poisoned = ShowLink.poisonedTokens(seen)
        for p in stored {
            for token in (tokensByRow[ObjectIdentifier(p)] ?? []).subtracting(poisoned) {
                groups["token:" + token + "|" + canonVenue(p.venue), default: []].append(p)
            }
        }

        for (_, members) in groups where members.count > 1 {
            // A shared id can be a SEASON marker rather than a production id: the extract runbook tells
            // the AI to copy any "Series:" line verbatim, and "Series: Broadway Sessions" spans different
            // shows. Same corroboration #1528 requires before letting an id carry identity, for the same
            // reason: fusing two shows would move a dismissal and a sent email onto the wrong one (#797).
            let title = members[0].groupName
            guard members.allSatisfy({ GroupNameMatch.isConfident($0.groupName, title) }) else { continue }

            // #1845: the NAMED deferral decision (#1780), the same one #1064 and #1590 ask. The
            // hand-rolled test here counted a bare dismissal and a merely-FOUND address as reasons to
            // refuse, so this pass had the same permanent-deferral defect measured on the live store in
            // #1590's pass. Swept here in the same change rather than left as the next instance.
            if NaturalKeyVenueMigration.mustDefer(members) {
                let withHistory = members.filter(NaturalKeyVenueMigration.hasOutreachHistory)
                // Never resolved blind. Merging two real outreach records is Dan's call, not a migration's
                // (the same rule #1064 follows). The Passion of Mr. Cardboard lands here.
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                // #1689: a NOTE. Correct, deliberate, and repeated on every launch (#1639).
                AgentLog.note("#1559 DriftedRunMerge: \(withHistory.count) rows of one run carry outreach history; leaving them for Dan.")
                // copy-inventory:ignore-end
                summary.conflictsDeferred += 1
                continue
            }

            // A row that reached the outside world wins. Otherwise the FRESHEST does, and that is the whole
            // difference from #1064: these rows are a time series, so the earliest is the most stale, is
            // typically already past FeedReconcile's gone threshold, and is the one the queue is ALREADY
            // hiding. Keeping it would delete the only card Dan can see (measured: Dukes, Jena Friedman).
            // #1845 inserts the contact-list rung, for the same reason as the other passes: the losing
            // copy's found addresses are deleted with it. #2001 makes every rung below the first choose
            // from the rows Dan has NOT decided about, so a night he refused makes way for one he has not
            // and the show comes back for another look.
            let candidates = NaturalKeyVenueMigration.preferringASecondLook(members)
            let freshestFirst = candidates.sorted { $1.ingestedAt < $0.ingestedAt }
            let survivor =
                // #4024: `first` is safe here ONLY because `mustDefer` above has already refused the
                // case where two rows could match: the strict record test implies `hasOutreachHistory`,
                // so two matches force a deferral before this line runs. That is behaviour correct as a
                // side effect of a rule written elsewhere, so it is owned by
                // `DeferralProtectsTheFirstRungTests` rather than by this comment (L281).
                members.first(where: {
                    NaturalKeyVenueMigration.hasRecordBeyondADismissal($0, countingFoundAddresses: false)
                })
                ?? NaturalKeyVenueMigration.richestContactList(freshestFirst)
                ?? candidates.max(by: { $0.ingestedAt < $1.ingestedAt })!

            // #3597: whatever only a loser knew, before the losers go (L5). This pass carried NOTHING,
            // so a merge here silently dropped the earliest sighting, any rename Dan had made, and the
            // identity the feed is currently publishing. The miss count reset below used to be the one
            // thing it did carry, and it is now part of this, which is why it has moved up.
            //
            // #3778: the returned KEY is DISCARDED here, as `NaturalKeyVenueMigration` already discards
            // it, and this is the one caller where adopting it produces a broken row. The key is
            // `title|date|venue` and this pass's members differ in exactly that date, because its whole
            // subject is a run whose opening night MOVED. So the adopted key names one night while the
            // survivor's own `performanceDate` names another, and a key derived from a record's fields
            // is only as good as its agreement with them (L15). Everything else `carry` does is assigned
            // inside it and is kept: the first sighting, Dan's decisions, the feed's listing URLs and
            // source ids, and the miss count reset.
            //
            // Safe to discard rather than merely less wrong, and that is the half worth checking before
            // changing this back. #3379 adopts the key because a survivor holding a key the source can
            // never produce again is unmatchable, so the next scout mints a twin and the loop has no end.
            // That reasoning is about a row reachable ONLY by its natural key. This pass's rows are not:
            // `ScoutService.matchByConcertIdentity` finds them by `seriesId` plus venue, title and run
            // overlap, never by key, and its update arm then writes `naturalKey` and `performanceDate`
            // together, so the next sweep re-keys the survivor and re-dates it in one consistent write.
            // That is what the code this replaced meant by "the next scout re-keys the survivor through
            // #1528's own match", checked against ScoutService rather than taken from the comment (L61).
            SurvivorInheritance.carry(onto: survivor, from: members)

            for loser in members where loser.persistentModelID != survivor.persistentModelID {
                context.delete(loser)
                summary.duplicatesDeleted += 1
            }
        }

        return summary
    }

    // Matches ScoutService.sameVenue, not the natural key's normalization, and the choice is deliberate:
    // the stricter rule merges FEWER rows, which is the safe direction for an operation that deletes, and
    // it agrees with the matching #1528 actually performs going forward.
    private static func canonVenue(_ venue: String?) -> String {
        (venue ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    }
}
