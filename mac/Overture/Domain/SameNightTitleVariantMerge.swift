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
// #1761: THE ROOM NO LONGER TAKES PART. This pass used to bucket rows on the night AND the folded venue
// key, so it could only ever see a duplicate that already agreed on the room. One source page scouted
// twice, transcribing its own room differently the second time ("Jalopy Theatre" one week, "Jalopy
// Theater" the next), landed in two buckets and stayed two cards forever.
//
// LIVE-STORE-CLAIM verified=2026-07-30 measure="same-night groups whose titles confidently match, the duplicate rows they hold, and how many the shipped pass caught"
// Measured over all 742 dated rows on 2026-07-30: 26 such groups holding 32 duplicate rows, 23 of them
// inside the 90-day queue window. The pass as it stood caught 3 of the 26. It had already cost 7 paid
// contact lookups spent twice on one show, and 12 of the 26 groups hold copies that disagree about the
// show's fit score, one by 8 points, so a duplicate also corrupts the order Dan triages in.
//
// Four candidate rules were scored against the whole store before this one was chosen (room-name
// containment, a spelling-distance test, a shared listing link, and a connectivity rule). Every one of
// them was strictly worse, and the link in particular found NOTHING the title match did not. All 26
// groups were then read by hand: each is one show. Dan's call on the residue, 2026-07-30: if the title is
// the same on the same night, one pitch covers it, so it is one card, even for the single group whose
// rooms genuinely differ (a festival playing a church and a theatre on one night). So the merge now rests
// on the night plus a confident title match, and the TITLE is the only thing holding the line: see
// SameNightRoomVariantMergeTests for the guards that pin it.
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

        // #1761: the venue no longer takes part. It used to bucket the rows, which meant one room spelled
        // two ways ("Jalopy Theatre" against "Jalopy Theater") produced two buckets and the pass could
        // never see the pair at all. Grouping on the night alone lets the title decide, which is the whole
        // point of this pass; see the file header for why the room was dropped rather than fuzzily matched.
        var groups: [String: [Prospect]] = [:]
        for p in stored {
            guard let date = p.performanceDate, !date.isEmpty else { continue }
            groups[date, default: []].append(p)
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
                // #1761: the survivor is chosen for what it HOLDS (Dan's decision, a paid answer, its
                // age), which is a different question from which row names the room best. Since the room
                // no longer gates the merge, a cluster can hold several spellings of one place and the
                // survivor is often not the clearest of them: the Brooklyn Folk Festival's oldest row
                // says "specific venue not named on page" while a row naming a real church is about to be
                // deleted, and the Derek Piotr workshop's oldest row says "Jalopy Theatre" while the room
                // it is actually in, "Jalopy's Classroom", is on a row being deleted. Carry the clearest
                // name across before the others go, so the card Dan reads names the room.
                if let clearest = clearestRoomName(in: cluster) { survivor.venue = clearest }
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

    // #1761: the most specific room name in a cluster, measured on the venue's OWN name (keyName drops
    // the street address and the trailing city, so a row is not "clearest" merely for carrying a postcode)
    // and counted in words. "Jalopy's Classroom at 319 Columbia St" beats "Jalopy Theatre";
    // "St. Ann & the Holy Trinity Church" beats "downtown Brooklyn"; "Roulette Intermedium" beats
    // "Roulette". Returns nil on a tie or when nothing beats the survivor's own, so the common case where
    // every row spells the room the same way leaves the field untouched.
    private static func clearestRoomName(in cluster: [Prospect]) -> String? {
        func specificity(_ venue: String?) -> Int {
            let name = VenueNormalization.keyName(venue ?? "")
            return name.split(whereSeparator: { $0.isWhitespace }).count
        }
        let best = cluster.max { specificity($0.venue) < specificity($1.venue) }
        guard let best, let venue = best.venue, !venue.isEmpty else { return nil }
        let tiedAtBest = cluster.filter { specificity($0.venue) == specificity(best.venue) }
        guard tiedAtBest.count == 1 else { return nil }
        return venue
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
