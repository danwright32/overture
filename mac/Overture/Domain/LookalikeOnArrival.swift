import Foundation

// #3330: does this arriving show look like one already stored?
//
// WHY IT EXISTS. When a source lists one show twice, or one source publishes through two hosts, the two
// listings share no identifier, so every arm of `ScoutService.upsertTarget` misses and the second row is
// INSERTED. Nothing joins them until `SameNightTitleVariantMerge` runs at the next launch. Dan meets two
// cards, pays for two reachability checks, and the pairing is invisible to him in the meantime.
//
// DAN'S CALL, 2026-09-21, with the measurement the issue asked for in front of him: tag the pair, never
// refuse the insert. So this answers WHICH stored row the arrival resembles, and the caller records it.
// It never decides whether to write the row, and cannot: it is handed the stored rows after the upsert
// has already chosen to insert.
//
// THE PREDICATE IS THE MERGE'S OWN, `GroupNameMatch.isSameNightVariant`, which is what
// `SameNightTitleVariantMerge.clusters` calls. That judgement was scored against the whole store in
// #1761 and chosen over three rivals, and it is already trusted enough to DELETE rows with, so using it
// to draw a sentence is strictly the lesser claim. A second, gentler rule here would be a second
// vocabulary for one question (L263).
//
// NARROWER THAN THE MERGE IN ONE PLACE, deliberately: it asks for the same VENUE as well as the same
// night. The merge is venue blind since #1761, on Dan's rule that one title on one night is one pitch
// whatever the rooms say (reaffirmed on #4117 on 2026-09-21). That rule is about what he PITCHES. This
// is about what a card CLAIMS, and a sentence telling him a show at another venue is a duplicate is a
// claim the merge never makes out loud. Sharing the merge's predicate where both ask the same question
// and diverging where they do not is the point (L342).
//
// MEASURED before it was built, over a WAL inclusive clone of 1,333 rows
// (`SameVenueOneNightSweepTests`, 2026-09-21): 2 same-venue pairs this would tag, both one show, zero
// wrong.
enum LookalikeOnArrival {

    // The natural key of the stored row this arrival resembles, or nil.
    //
    // The FIRST match in the order given, and the caller hands them in a stable order, because the tag
    // is a pointer to one row and a set of them would be a different sentence. Where an arrival
    // resembles several, naming the first is enough for the note it draws: what Dan needs is that a
    // lookalike exists and which one to compare against, and the launch merge collapses the whole
    // cluster rather than a pair.
    static func amongStored(_ stored: [(key: String, groupName: String, performanceDate: String?,
                                        venue: String?)],
                            groupName: String, performanceDate: String?, venue: String?,
                            excludingKey: String) -> String? {
        guard let performanceDate, !performanceDate.isEmpty else { return nil }
        let room = foldedVenue(venue)
        return stored.first { candidate in
            candidate.key != excludingKey
                && candidate.performanceDate == performanceDate
                && foldedVenue(candidate.venue) == room
                && GroupNameMatch.isSameNightVariant(candidate.groupName, groupName)
        }?.key
    }

    // The same fold the natural key is built through, so two spellings of one room are one room here as
    // well. Read from `VenueNormalization` rather than spelled again (L370).
    private static func foldedVenue(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return VenueNormalization.normalizeForKey(raw).lowercased()
    }
}
