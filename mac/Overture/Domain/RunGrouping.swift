import Foundation

// Collapse a multi-night run (same venue, a similar enough act name, performances <=3 days
// apart) into the opening night, tagged with the run's closing date, all member source URLs,
// and a flag when the same venue has more than one run/date for that act in the batch.
// #369: title matching uses GroupNameMatch.isConfident (a shared name-similarity check, already
// used for repeat-client history matching) instead of exact string equality, so a ceremony and
// its differently-titled sub-event (e.g. a "Guest Artist:" night) still merge.
enum RunGrouping {
    struct RunRow: Equatable, Sendable {
        var groupName: String
        var venue: String?
        var performanceDate: String?
        var sourceListingURL: String?
    }

    struct GroupedRun: Equatable, Sendable {
        var row: RunRow
        var runEndDate: String?
        var partOfRelatedRun: Bool
        var runSourceURLs: [String]
    }

    private static let gapDays = 3

    private static func canon(_ s: String?) -> String {
        (s ?? "").lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // #369: among a run's member rows, the shortest (fewest tokens) groupName reads as the
    // general/parent title rather than a specific sub-event's, so it becomes the run's
    // displayed representative regardless of which night happens to be chronologically first.
    // Ties (equal token count, including the common case where every row in the run shares the
    // exact same title) keep the first row in chronological order, since `run` is already
    // date-sorted and Sequence.min(by:) returns the first minimal element on a tie.
    private static func representativeRow(_ run: [RunRow]) -> RunRow {
        run.min(by: { GroupNameMatch.tokens($0.groupName).count < GroupNameMatch.tokens($1.groupName).count }) ?? run[0]
    }

    static func group(_ rows: [RunRow]) -> [GroupedRun] {
        let undated = rows.filter { $0.performanceDate == nil }
        let dated = rows.filter { $0.performanceDate != nil }

        // #369: bucket by venue only now; title similarity (not exact equality) decides which
        // same-venue rows belong together, checked during the chronological walk below.
        var order: [String] = []
        var byVenue: [String: [RunRow]] = [:]
        for r in dated {
            let key = canon(r.venue)
            if byVenue[key] == nil { order.append(key); byVenue[key] = [] }
            byVenue[key]?.append(r)
        }

        var out: [GroupedRun] = []
        for key in order {
            let venueRows = (byVenue[key] ?? []).sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }
            var runs: [[RunRow]] = []
            for r in venueRows {
                if let last = runs.last, let prev = last.last,
                   let gap = EasternDate.daysUntil(from: prev.performanceDate!, to: r.performanceDate!),
                   gap <= gapDays,
                   GroupNameMatch.isConfident(prev.groupName, r.groupName) {
                    runs[runs.count - 1].append(r)
                } else {
                    runs.append([r])
                }
            }
            // #369: a run is "related" to another run at this same venue only when their
            // representative titles are the same act by GroupNameMatch, not merely "this venue
            // produced more than one run" (which would also flag two genuinely different,
            // unrelated acts that happen to share a venue). This generalizes the old exact-key
            // behavior (same title, same venue, split by a date gap) to the new similarity check.
            for (i, run) in runs.enumerated() {
                let open = representativeRow(run)
                let related = runs.indices.contains { j in
                    j != i && GroupNameMatch.isConfident(open.groupName, representativeRow(runs[j]).groupName)
                }
                out.append(GroupedRun(
                    row: open,
                    runEndDate: run.count > 1 ? run.last?.performanceDate : nil,
                    partOfRelatedRun: related,
                    runSourceURLs: run.compactMap { $0.sourceListingURL }
                ))
            }
        }
        for r in undated {
            out.append(GroupedRun(row: r, runEndDate: nil, partOfRelatedRun: false,
                                  runSourceURLs: r.sourceListingURL.map { [$0] } ?? []))
        }
        return out
    }
}
