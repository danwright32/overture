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

        for (_, members) in groups where members.count > 1 {
            // A shared id can be a SEASON marker rather than a production id: the extract runbook tells
            // the AI to copy any "Series:" line verbatim, and "Series: Broadway Sessions" spans different
            // shows. Same corroboration #1528 requires before letting an id carry identity, for the same
            // reason: fusing two shows would move a dismissal and a sent email onto the wrong one (#797).
            let title = members[0].groupName
            guard members.allSatisfy({ GroupNameMatch.isConfident($0.groupName, title) }) else { continue }

            let withHistory = members.filter(NaturalKeyVenueMigration.hasOutreachHistory)
            if withHistory.count >= 2 {
                // Never resolved blind. Merging two real outreach records is Dan's call, not a migration's
                // (the same rule #1064 follows). The Passion of Mr. Cardboard lands here.
                // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                NSLog("#1559 DriftedRunMerge: %d rows of one run carry outreach history; leaving them for Dan.",
                      withHistory.count)
                // copy-inventory:ignore-end
                summary.conflictsDeferred += 1
                continue
            }

            // The row holding Dan's decision wins. With none, the FRESHEST wins, and that is the whole
            // difference from #1064: these rows are a time series, so the earliest is the most stale, is
            // typically already past FeedReconcile's gone threshold, and is the one the queue is ALREADY
            // hiding. Keeping it would delete the only card Dan can see (measured: Dukes, Jena Friedman).
            let survivor = withHistory.first
                ?? members.max(by: { $0.ingestedAt < $1.ingestedAt })!

            for loser in members where loser.persistentModelID != survivor.persistentModelID {
                context.delete(loser)
                summary.duplicatesDeleted += 1
            }

            // The survivor inherited the miss count of a row the feed stopped listing, so it would render
            // struck through as "No longer in the feed, may be cancelled" for a run still weeks from
            // closing. The run IS still listed; only its opening night moved.
            survivor.missedScoutCount = 0

            // Deliberately NOTHING else. The key and the date are left exactly as they are: the next scout
            // re-keys the survivor through #1528's own match, and rewriting a key here is the only step
            // that could throw against the unique index, inside a launch save shared with every other
            // migration whose failure is currently discarded.
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
