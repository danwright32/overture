import Foundation

// Collapse a multi-night run (same group + venue, performances <=3 days apart) into the
// opening night, tagged with the run's closing date, all member source URLs, and a flag
// when the same group+venue has more than one run/date in the batch. Mirrors runGrouping.ts.
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

    private static func dayNumber(_ date: String) -> Int {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return 0 }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let secs = cal.date(from: c)?.timeIntervalSince1970 ?? 0
        return Int(secs / 86_400)
    }

    static func group(_ rows: [RunRow]) -> [GroupedRun] {
        let undated = rows.filter { $0.performanceDate == nil }
        let dated = rows.filter { $0.performanceDate != nil }

        var order: [String] = []
        var byGroup: [String: [RunRow]] = [:]
        for r in dated {
            let key = "\(canon(r.groupName))|\(canon(r.venue))"
            if byGroup[key] == nil { order.append(key); byGroup[key] = [] }
            byGroup[key]?.append(r)
        }

        var out: [GroupedRun] = []
        for key in order {
            let group = (byGroup[key] ?? []).sorted { ($0.performanceDate ?? "") < ($1.performanceDate ?? "") }
            var runs: [[RunRow]] = []
            for r in group {
                if let last = runs.last, let prev = last.last,
                   dayNumber(r.performanceDate!) - dayNumber(prev.performanceDate!) <= gapDays {
                    runs[runs.count - 1].append(r)
                } else {
                    runs.append([r])
                }
            }
            let related = runs.count > 1
            for run in runs {
                let open = run[0]
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
