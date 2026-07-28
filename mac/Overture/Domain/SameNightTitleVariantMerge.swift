import Foundation
import SwiftData

// #1590 part two: one show BILLED two ways on the same night, in the same room, sitting in the queue as
// two cards Dan has to dismiss separately.
//
// Why this is a separate pass from the key fold. TitleNormalization folds the punctuation class into the
// natural key, which is the right home for it: a canonical fold is a FUNCTION, so it can feed a unique
// column and it can never fuse two titles that do not reduce to the same string. It therefore cannot
// reach the other half of the live duplication, where the titles differ by real WORDS:
//   "FRIGID Nightcap"                          / "FRIGID Nightcap: FUTURE TENSE"
//   "Fleetwood Mac: Stripped"                  / "Fleetwood Mac: Stripped (Broadway Sings)"
//   "Sins and Stardust Burlesque: Tribute to the Ruby" / ": August 31st" / ": Tribute to the 80s"
// Deciding those are one show is a similarity JUDGMENT. Keeping the judgment out of the key is the point:
// nothing that deletes a row should rest on a merge the key made silently, where no summary counts it and
// no log records it.
//
// LIVE-STORE-CLAIM verified=2026-07-27 measure="same-night same-venue groups whose titles are a confident name match but differ by real words, and the duplicate cards they cost"
// Measured on the live store 2026-07-27: 7 such groups, 8 duplicate cards, on top of the 10 the fold
// collapses. Each duplicate is also a duplicate PAID reachability lookup since milestone 32.
//
// BLAST RADIUS. This DELETES prospect rows, so it takes its safety rules verbatim from the two passes
// that already do (#1064 NaturalKeyVenueMigration, #1559 DriftedRunMerge), and the launch backup
// (#601/#602) taken just before migrations run is what makes it recoverable:
//   - SAME NIGHT only. Two nights of one show are a RUN, and RunGrouping owns those; widening this to a
//     date range would delete the second night of a run Dan can still shoot.
//   - An undated row has no night to share and is never grouped.
//   - Every member of a group must confidently match the FIRST one (GroupNameMatch.isConfident), not just
//     its neighbour, so a chain of loose pairs can never drag two unrelated acts together.
//   - When two or more rows carry outreach history the group is left exactly as it is and the conflict is
//     logged. Merging two real outreach records is Dan's call, not a migration's.
//
// Runs at every launch rather than once: a source keeps republishing its variants, so new pairs keep
// arriving. Idempotent, because a collapsed group is a singleton and singletons are skipped.
enum SameNightTitleVariantMerge {
    struct Summary: Equatable {
        var duplicatesDeleted = 0
        var conflictsDeferred = 0
    }

    @discardableResult
    static func run(in context: ModelContext) -> Summary {
        let stored = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var summary = Summary()

        // The venue half folds through VenueNormalization, the SAME reduction the natural key and
        // RunGrouping use, so a row carrying the street address still counts as the same room.
        var groups: [String: [Prospect]] = [:]
        for p in stored {
            guard let date = p.performanceDate, !date.isEmpty else { continue }
            let venueKey = VenueNormalization.normalizeForKey(p.venue ?? "").lowercased()
            groups[date + "|" + venueKey, default: []].append(p)
        }

        for (_, members) in groups where members.count > 1 {
            // Oldest first, so the cluster representative and the fallback survivor are both stable and
            // do not depend on fetch order.
            let ordered = members.sorted { $0.ingestedAt < $1.ingestedAt }

            for cluster in clusters(of: ordered) {
                guard cluster.count > 1 else { continue }

                let withHistory = cluster.filter(NaturalKeyVenueMigration.hasOutreachHistory)
                if withHistory.count >= 2 {
                    // copy-inventory:ignore-start  developer diagnostic log, not the app's own voice (#915)
                    NSLog("#1590 SameNightTitleVariantMerge: %d rows of one night carry outreach history; leaving them for Dan.",
                          withHistory.count)
                    // copy-inventory:ignore-end
                    summary.conflictsDeferred += 1
                    continue
                }

                let survivor = withHistory.first ?? probed(cluster) ?? cluster[0]
                for loser in cluster where loser.persistentModelID != survivor.persistentModelID {
                    context.delete(loser)
                    summary.duplicatesDeleted += 1
                }
            }
        }

        return summary
    }

    // A reachability check costs real money and real minutes, and a probe that concluded "no email found"
    // leaves NO recipients behind, so it does not read as outreach history. Without this the merge would
    // happily delete the row holding the paid answer and keep the unprobed one, which silently throws the
    // answer away and re-offers the same check. A probed row outranks an unprobed one.
    private static func probed(_ cluster: [Prospect]) -> Prospect? {
        cluster.first { $0.reachabilityProbedAt != nil }
    }

    // Greedy clustering against each cluster's FIRST member, never its most recent one, so membership is
    // decided by one representative title rather than by a chain of pairwise near-matches that could walk
    // from one act to an unrelated one.
    private static func clusters(of rows: [Prospect]) -> [[Prospect]] {
        var out: [[Prospect]] = []
        for r in rows {
            if let i = out.firstIndex(where: {
                GroupNameMatch.isConfident($0[0].groupName, r.groupName,
                                           minimumContainment: GroupNameMatch.sameNightContainmentFraction)
            }) {
                out[i].append(r)
            } else {
                out.append([r])
            }
        }
        return out
    }
}
