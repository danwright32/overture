import Foundation

// #4067: the identity a HUMAN VERDICT about a pair of rows is recorded against.
//
// IN `OvertureTests` RATHER THAN `TestSupport`, and the reason is the constraint `LiveContactShape`
// already records: TestSupport is compiled into BOTH test targets, which reach the app differently (the
// unhosted target compiles its sources in, the hosted one imports the built module), so a file shared
// between them cannot name `Prospect` at all. Both sweeps that hold a verdict live in this target, so
// this is the narrowest place that can carry the rule rather than a copy of it.
//
// Two live-store sweeps hold a set of pairs a person read by eye and settled (`TwoShowsOneTitleOneNight`
// for the cross-venue question, `SameVenueOneNightSweep` for the same-venue one). Both keyed those
// verdicts on `Prospect.naturalKey`, and that key is precisely what this milestone exists to change:
// every re-key arm in `upsertTarget` writes a new one onto a stored row, and three launch passes do the
// same. A settled verdict is only as durable as the key it is written against (L15, L186).
//
// What happens when one row of a judged pair re-keys: the entry silently stops matching, the pair comes
// back as UNJUDGED, and the sweep fails naming it. Two bad outcomes follow and neither is obviously
// wrong at the time. Somebody re-reads and re-judges a pair another person already settled. Or somebody
// reads the stale entry as residue and deletes it, which throws away the JUDGEMENT rather than the key.
//
// It is not hypothetical for this population: the judged Abrons Arts Center pairs are venue-name
// variants, and `NaturalKeyVenueMigration` re-keys on exactly that axis at launch.
//
// SO THE VERDICT IS KEYED ON WHAT WAS JUDGED, not on which rows carried it. The person looked at a
// folded title, a NIGHT the two rows share, and two rooms. Each of those is either what the pair is
// about or is recomputed from the row's current fields, so a re-key that moves an opening night or
// realigns a venue spelling leaves the verdict matching.
//
// WHAT IT DELIBERATELY DOES NOT USE. The natural key's date field is the OPENING night, and the pair was
// judged on a night they SHARE, which for a run and a single night inside it are different days. That
// mismatch is one of the two ways the old key moved under a settled verdict; the other is the venue.
struct JudgedPair: Hashable, Sendable {
    // BOTH folded titles, sorted, not one. The same-venue sweep's judged pairs differ in exactly this
    // field ("macmccarty +kiddtwist" against "macmccarty + kiddtwist"), so a key built from one row's
    // title would depend on which of the two the caller happened to pass first, and the same pair read
    // in the other order would read as unjudged. Sorting both is what makes the verdict order free
    // (L228: a comparison of two things as SETS says nothing about their order, which is the property
    // wanted here).
    let foldedTitles: [String]
    let night: String
    let foldedVenues: [String]

    init(foldedTitles: [String], night: String, venues: [String]) {
        self.foldedTitles = foldedTitles.sorted()
        self.night = night
        self.foldedVenues = venues.sorted()
    }

    /// The verdict key for two rows judged on one night, computed from their CURRENT fields.
    static func of(_ a: Prospect, _ b: Prospect, night: String) -> JudgedPair {
        JudgedPair(foldedTitles: [a, b].map {
                       TitleNormalization.normalizeForKey(Prospect.canonicalize($0.groupName))
                   },
                   night: night,
                   venues: [a, b].map { VenueNormalization.normalizeForKey($0.venue ?? "") })
    }

    /// How an entry is written in a sweep's judged list, and how a failure names one, so a reader can
    /// tell a genuinely new pair from one whose rows moved underneath a verdict.
    var description: String {
        "\(foldedTitles.joined(separator: " || ")) on \(night) at \(foldedVenues.joined(separator: " || "))"
    }
}
