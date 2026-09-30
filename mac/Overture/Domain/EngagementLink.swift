import Foundation

// #939: RunGrouping only ever collapses nights at the SAME venue into one run. A same production
// touring several DIFFERENT community venues on nearby dates (a recurring Carnegie calendar pattern)
// lands in one Prospect row per venue with no relationship recorded between them, so a surface that
// only looks at one row's own date (the #924 dismiss-to-day-off offer) sees only that one date.
//
// This is the second pass: it links rows across venues so a surface can act on the whole engagement.
// It deliberately requires an EXACT normalized-title match, not GroupNameMatch.isConfident's looser
// containment rule (which is safe for RunGrouping, where it only ever compares rows already known to
// be at the same venue): reused unmodified across every venue in the app, containment would wrongly
// link two different orgs whose names happen to overlap (GroupNameMatch.swift's own documented example,
// "New York Ballet" vs "New York Theatre Ballet").
enum EngagementLink {
    struct Row: Equatable, Sendable {
        // The prospect's own naturalKey, so the caller can look its own dismissal back up in the result.
        var id: String
        var groupName: String
        var venue: String?
        var performanceDate: String?
        var runEndDate: String? = nil
    }

    struct Member: Equatable, Hashable, Sendable {
        var venue: String?
        var date: String
    }

    private static func canon(_ s: String?) -> String {
        (s ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    }

    // For each row id, the OTHER dates/venues in its cross-venue engagement (absent if none).
    static func group(_ rows: [Row]) -> [String: [Member]] {
        let dated = rows.filter { $0.performanceDate != nil }

        var byTitle: [String: [Row]] = [:]
        for r in dated {
            byTitle[GroupNameMatch.normalize(r.groupName), default: []].append(r)
        }

        var out: [String: [Member]] = [:]
        for (_, titleRows) in byTitle {
            // #4346 (plan v7 Step T): a TOTAL order. By date alone, two rows opening on one night kept the
            // order they arrived in, and the chain below compares each row with the row appended LAST, so
            // which of the two landed last decided whether a later row joined (Step T0 reproduced it). Run
            // end, then room, then the natural key make the walk, and so the membership, the same however
            // the rows arrive. A row with no run end sorts before one with a run end on the same night.
            let sorted = titleRows.sorted {
                ($0.performanceDate ?? "", $0.runEndDate ?? "", $0.venue ?? "", $0.id)
                    < ($1.performanceDate ?? "", $1.runEndDate ?? "", $1.venue ?? "", $1.id)
            }
            // #4347 (plan v7 decision 18(b), Dan's call 2026-09-27): a row joins when it falls within the gap
            // of the LATEST closing night the engagement has reached so far, not the closing night of
            // whichever row happened to be appended last. The old anchor let a one-night show nested inside
            // a long run pull the engagement's end back to its own night, so a later room still inside the
            // run was measured from the short show and split off. Measured before the change: 0 live rows
            // move (probe 0c.10).
            var clusters: [[Row]] = []
            var latestLastNight: String? = nil
            for r in sorted {
                let ownLastNight = EasternDate.runLastNight(runEndDate: r.runEndDate, performanceDate: r.performanceDate)
                if !clusters.isEmpty, let anchor = latestLastNight,
                   let gap = EasternDate.daysUntil(from: anchor, to: r.performanceDate!),
                   gap <= RunGrouping.gapDays {
                    clusters[clusters.count - 1].append(r)
                    if let ownLastNight, ownLastNight > anchor { latestLastNight = ownLastNight }
                } else {
                    clusters.append([r])
                    latestLastNight = ownLastNight
                }
            }
            for cluster in clusters {
                // A cluster confined to one venue is RunGrouping's own job (its `partOfRelatedRun`
                // case); only report a cluster that actually spans more than one venue.
                guard Set(cluster.map { canon($0.venue) }).count > 1 else { continue }
                for r in cluster {
                    out[r.id] = cluster.filter { $0.id != r.id }
                        .map { Member(venue: $0.venue, date: $0.performanceDate!) }
                }
            }
        }
        return out
    }
}

extension EngagementLink.Row {
    init(_ p: Prospect) {
        self.init(id: p.naturalKey, groupName: p.groupName, venue: p.venue,
                  performanceDate: p.performanceDate, runEndDate: p.runEndDate)
    }
}
