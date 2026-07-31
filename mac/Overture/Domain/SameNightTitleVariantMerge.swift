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
        let watched = watchedRoomNames(in: context)
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
                // deleted. Carry a name across before the others go, so the card Dan reads names the room.
                // #1846 decides WHICH name: the one Dan entered when he started watching the venue, when
                // a copy already spelled the room that way, and the most specific copy otherwise.
                if let room = preferredRoomName(in: cluster, watched: watched) { survivor.venue = room }
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

    // #1846: the name DAN gave a room when he started watching it, keyed by the room's own fold so a copy
    // carrying the street or the town still finds it. `venueName` first (the field that exists to hold an
    // asserted room, #1529) and `orgName` behind it, which is where every name actually lives today: 0 of
    // the 69 live sources carry a venueName, while orgName holds "Jalopy Theatre", "Roulette Intermedium",
    // "Abrons Arts Center".
    //
    // Deliberately keyed on the NAME rather than on which source produced the row. A room Dan named is the
    // same room whoever lists the show, so a Jalopy gig found through an artist's own page still gets the
    // name he gave the venue, and the rule does not quietly depend on `sourceIds` being populated.
    private static func watchedRoomNames(in context: ModelContext) -> [String: String] {
        let sources = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []
        var byKey: [String: String] = [:]
        for source in sources {
            let name = source.venueName ?? source.orgName
            let key = VenueNormalization.normalizeForKey(name).lowercased()
            guard !key.isEmpty else { continue }
            byKey[key] = name
        }
        return byKey
    }

    // #1846: which room the surviving card names. Dan's rule, in his words: "If it's a known venue that I
    // watch, it should go to the venue that I entered when we started watching it. If it's a new venue
    // because I'm watching the artist and we don't know it, it can go to the more specific one."
    //
    // The entered name wins only WHEN ONE OF THE COPIES ALREADY SPELLED THE ROOM THAT WAY, which is the
    // condition that makes the rule safe. A watched source is not necessarily one room: 11 of them publish
    // shows naming more than one, and Carnegie Hall alone names 26 distinct room strings across 117 rows,
    // with nothing in the model marking which sources are venues and which are ensembles Dan follows from
    // hall to hall (SourceKind deliberately refuses to answer it, since Jalopy's page is one room and
    // Carnegie's is thirteen). Let the entered name win unconditionally and a Zankel Hall concert reads
    // "Carnegie Hall", losing the only thing about the room that matters to a photographer. Requiring a
    // copy to have used the name keeps the building out of a card whose copies all name a hall inside it.
    private static func preferredRoomName(in cluster: [Prospect],
                                          watched: [String: String]) -> String? {
        // #1850: the entered name may not overwrite a spelling that NAMES MORE. Dan watches "Abrons Arts
        // Center", and a copy of the same show says "Experimental Theater at Abrons Arts Center"; taking
        // the entered name there deletes the room from the only row that held it, and no display change
        // made later can bring it back. So the entered name wins only when nothing more specific was said,
        // and the card shows the building leading with the room in brackets instead of choosing.
        let mostSpecific = cluster.map { specificity($0.venue) }.max() ?? 0
        for row in cluster {
            let key = VenueNormalization.normalizeForKey(row.venue ?? "").lowercased()
            guard let entered = watched[key] else { continue }
            if specificity(entered) >= mostSpecific { return entered }
            break
        }
        return clearestRoomName(in: cluster)
    }

    // #1761: the most specific room name in a cluster, measured on the venue's OWN name (keyName drops
    // the street address and the trailing city, so a row is not "clearest" merely for carrying a postcode)
    // and counted in words. "Jalopy's Classroom at 319 Columbia St" beats "Jalopy Theatre";
    // "St. Ann & the Holy Trinity Church" beats "downtown Brooklyn"; "Roulette Intermedium" beats
    // "Roulette". Returns nil on a tie or when nothing beats the survivor's own, so the common case where
    // every row spells the room the same way leaves the field untouched.
    // How much a venue string says, counted in words on the venue's OWN name (keyName drops the street
    // address and the trailing city, so a row is not "clearest" merely for carrying a postcode).
    private static func specificity(_ venue: String?) -> Int {
        VenueNormalization.keyName(venue ?? "").split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func clearestRoomName(in cluster: [Prospect]) -> String? {
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
            // #1764: isSameNightVariant, not isConfident, so a misspelling inside the title is tolerated
            // here and NOWHERE else. The loosening is named at the call site rather than hidden in a
            // default, exactly as #1590 did for the containment fraction.
            if let i = out.firstIndex(where: {
                GroupNameMatch.isSameNightVariant($0[0].groupName, r.groupName)
            }) {
                out[i].append(r)
            } else {
                out.append([r])
            }
        }
        return out
    }
}
