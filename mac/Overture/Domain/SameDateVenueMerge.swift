import Foundation

// #1236: some sources list ONE concert as several rows, one per conductor/composer (DCINY's per-conductor
// listing style: Nov 16 2026 at Carnegie is three rows, "We Sing Noel" + Courtney + "The Four Freedoms",
// but one concert and one shoot). A plain scout makes one prospect per conductor, over-splitting the queue.
//
// This is unique to that listing style, so it is driven by a per-source flag (WatchedSource.mergeSameDateVenue),
// never applied globally: a normal presenter's matinee and evening on one date are two genuine concerts.
//
// The mechanism is pure reuse. We stamp a synthetic seriesId per (performanceDate, venue) at ingest, so the
// existing title-independent series collapse in RunGrouping fuses the rows into one Prospect even though
// their conductor titles differ. The one genuinely new step is rebuilding the merged name from every row's
// title, because that collapse otherwise keeps only one representative title and drops the rest, and here
// the conductor list IS the name (until /see-a-show/ names the concert, which is Half B, filed separately).
enum SameDateVenueMerge {

    // Namespaced so a downstream reader (ScoutService's collapse) can tell a synthetic same-date merge from
    // a real feed production id (VenueTix, #1174) and rebuild the name only for the former.
    static let seriesPrefix = "samedatevenue:"

    // Stamp the synthetic id on same-date, same-venue rows that don't already carry one. A real feed id
    // wins (never overwritten); a row with no date or no venue has nothing to key on and is left untouched
    // so it can never wrongly merge.
    static func stamped(_ events: [ExtractedEvent]) -> [ExtractedEvent] {
        events.map { e in
            guard (e.seriesId ?? "").isEmpty,
                  let date = e.performanceDate, !date.isEmpty,
                  let venue = e.venue, !venue.trimmingCharacters(in: .whitespaces).isEmpty
            else { return e }
            var out = e
            out.seriesId = syntheticSeriesId(date: date, venue: venue)
            return out
        }
    }

    // The venue is folded through the same normalization the natural key uses (VenueNormalization), so two
    // spellings of one venue still key together and match the bucket RunGrouping will collapse them in.
    static func syntheticSeriesId(date: String, venue: String) -> String {
        seriesPrefix + date + "|" + VenueNormalization.normalizeForKey(venue).lowercased()
    }

    static func isMerged(_ seriesId: String?) -> Bool {
        (seriesId ?? "").hasPrefix(seriesPrefix)
    }

    // Every row's title, in listing order, deduped, joined. Retaining all of them is the point: the fallback
    // name IS the conductor list.
    static func combinedName(from titles: [String]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for title in titles {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            kept.append(trimmed)
        }
        return kept.joined(separator: "; ")
    }
}
