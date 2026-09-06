import Foundation

// #3516: the live store's DATE clustering, in one place, because two cost fixtures need it and a rule's
// data shared while the code applying it is copied is not consolidation (L370).
//
// WHY IT MATTERS AT ALL. `SelfBookingConflict.NightIndex` buckets shows by night, and the work per row is
// the size of the bucket its nights fall in, so the self-booking check is quadratic in shows sharing a
// DATE and flat in row count. Both cost fixtures spread their dates evenly, which no dimension recorded,
// so nothing could say whether they exercised that term at the real intensity.
//
// THE ANSWER IS NOT THE LARGEST CLUSTER, which is what makes this worth a shared type rather than a
// constant. Measured 2026-09-05: an even spread of 1,142 rows over 108 dates has a SMALLER largest
// cluster than the live store (11 against 19) and a LARGER comparison load (12,102 against 9,037),
// because packing more rows into fewer dates raises the total while lowering the maximum. Drawing the
// queue on a stage that shows the marker examined 715 shows on that spread against 130 at the live
// clustering, so the fixture was exercising the term at five and a half times the real intensity while
// its largest cluster suggested half. The largest cluster bounds the worst single ROW; the sum of each
// date's squared size is what the pass pays (L391).
//
// So the shape recorded here is the whole SIZE HISTOGRAM, which is what fixes both at once. Neither
// number can be hit by choosing a spread: rows, distinct dates and largest cluster together leave the
// comparison load anywhere between about 6,000 and 12,000.
//
// Measured 2026-09-05 on a WAL-inclusive read-only copy of the live store: 1,153 prospects over 235
// distinct dates, NONE undated, spanning 2026-06-22 to 2027-07-08.
//
//   select c, count(*) from (select count(*) c from ZPROSPECT
//                            where ZPERFORMANCEDATE is not null and ZPERFORMANCEDATE <> ''
//                            group by ZPERFORMANCEDATE) group by c order by c;
//
// The DATES themselves are invented and walk forward from a fixed day. A distribution is not anybody's
// data, which is what makes deriving the shape from the live store and inventing every value the right
// design here (L48, and the privacy rule both fixtures state in their own headers).
enum LiveDateClustering {

    // LIVE-STORE-CLAIM verified=2026-09-05 measure="the performance-date size histogram: how many dates hold one show, two shows and so on, read with sqlite3 from a WAL-inclusive copy of the live store"
    //
    // (how many shows fall on a date, how many dates hold that many), as the live store holds it.
    static let histogram: [(size: Int, dates: Int)] = [
        (1, 66), (2, 21), (3, 21), (4, 16), (5, 14), (6, 21), (7, 19), (8, 15),
        (9, 8), (10, 13), (11, 6), (12, 7), (13, 5), (14, 1), (19, 2),
    ]

    static let rowsInTheLiveStore = 1153
    static let largestCluster = 19

    // One date per row, for a corpus of `count` rows carrying the live clustering.
    //
    // A corpus SHORTER than the live store drops shows from the single-show dates first, which is the
    // smallest possible edit to the real distribution and the one that moves the comparison load least:
    // at 1,142 rows that is eleven dates fewer and a load of 9,026 against 9,037. A corpus LONGER than it
    // repeats the histogram, so the shape holds as the store grows rather than the extra rows piling onto
    // one date.
    static func dates(forRows count: Int, from start: DateComponents = DateComponents(year: 2026, month: 8, day: 1)) -> [String] {
        var sizes: [Int] = []
        var covered = 0
        while covered < count {
            for bucket in histogram {
                for _ in 0..<bucket.dates {
                    sizes.append(bucket.size)
                    covered += bucket.size
                }
            }
            // A histogram that covers nothing would loop forever; it cannot, but a guard costs nothing
            // and a hang is worse than a failure (L110).
            if histogram.allSatisfy({ $0.size == 0 || $0.dates == 0 }) { break }
        }

        // INTERLEAVED, rather than laid down in histogram order. Written the obvious way, every
        // single-show date comes first and both nineteen-show dates land at the very end of the window,
        // so cluster size would correlate perfectly with how far ahead a show is, which is a shape the
        // live store has no reason to have and which every date-sensitive rule in the pass would read.
        // A fixed stride co-prime to the count spreads them deterministically, so two runs produce the
        // same corpus (L339).
        let total = sizes.count
        let stride = 97
        let spread = total > 0 ? (0..<total).map { sizes[($0 * stride) % total] } : []

        var out: [String] = []
        out.reserveCapacity(count)
        for (day, size) in spread.enumerated() {
            let date = dayString(offset: day, from: start)
            for _ in 0..<size where out.count < count { out.append(date) }
            if out.count >= count { break }
        }
        return out
    }

    private static func dayString(offset: Int, from start: DateComponents) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        var components = start
        components.day = (start.day ?? 1) + offset
        let date = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // What a corpus of these dates costs the self-booking check: the sum of each date's squared size,
    // which is the quantity `SelfBookingConflict` pays and the one the drift check compares.
    static func comparisonLoad(of dates: [String]) -> Int {
        var perDate: [String: Int] = [:]
        for date in dates { perDate[date, default: 0] += 1 }
        return perDate.values.reduce(0) { $0 + $1 * $1 }
    }
}
