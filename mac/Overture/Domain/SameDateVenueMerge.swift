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

    // #4040: the same question ANCHORED to the row asking it, which is the form every re-key must use.
    //
    // The bare `isMerged` above asks only whether a string starts with a prefix this app reserves. It asks
    // nothing about who wrote the string, and `matchByConcertIdentity` skips its title check and its run
    // overlap check on the strength of the answer. The arm's header justifies that by MINTING ("minted only
    // for a mergeSameDateVenue source"), which is a claim about every writer rather than about this reader,
    // and a value copied verbatim off a page by the extract run (`docs/scout-extract-runbook.md` 3b) can
    // satisfy the prefix without ever having been minted here.
    //
    // A synthetic id IS its row's date and its folded venue, so demanding that it NAMES them costs the
    // #1260 path nothing: a concert whose title changed on one date at one room still matches its own id.
    // What it removes is every case where the id says something the row does not, so a forged value can
    // only ever join rows that genuinely share the date and venue it names.
    //
    // Nil date or nil venue is always false. A row that cannot name itself must never authorize a re-key,
    // which is the direction `stamped` already takes (it refuses to stamp such a row) and the one
    // `ScoutService.runsOverlap` takes for an unknown date.
    static func isMerged(_ seriesId: String?, naming date: String?, venue: String?) -> Bool {
        guard let seriesId, let date, !date.isEmpty,
              let venue, !venue.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return seriesId == syntheticSeriesId(date: date, venue: venue)
    }

    // #4040: an id this app did not mint may not claim the namespace this app reserves.
    //
    // Applied where an event crosses IN from outside, so the ordering that matters holds by construction:
    // a value arriving with the prefix is disowned, and `stamped` then mints a real one for the sources
    // that are entitled to it.
    //
    // The FIELD is dropped, never the event. The show is real and Dan should still see it; what cannot be
    // trusted is one identifier, and losing it costs the row only a run collapse it was never entitled to.
    // Stated so the fallback's own cost is named rather than assumed (L93): a genuine feed id spelled this
    // way would be lost too, and no ticketing platform mints one, because the prefix is ours.
    static func disowningForgedId(_ seriesId: String?) -> String? {
        isMerged(seriesId) ? nil : seriesId
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
