import Foundation

// #1663 then #1949: what a row's classification holds when two sources describe one show differently.
//
// `ScoutExtractIngest` loops per source and calls `ScoutService.apply` once each, so with two sources the
// second one to run used to win outright. The provenance three lines away is a union, with a comment
// explaining why a replace there would be wrong; the classification was a replace with no rule at all.
//
// #1663 gave it a precedence: one source's reading, whole. #1949 replaced that with a MERGE, on Dan's call
// (2026-08-01) after seeing both side by side. The case that decided it: a venue's feed names the
// presenting organisation but lists a title with no genre word, while the artist's own page names the
// genre and no organisation. Neither describes the show properly, both know something real, and taking
// either one whole throws away a fact nobody else has.
//
// Two things make the merge safe rather than a way to inflate every score:
//
// 1. Axes merge by how INFORMATIVE they are, never by how well they score. `weak` is not a lesser
//    `strong`, it is the penalty an agency-routed showcase earns, and `agency` is not a worse `self`, it
//    is a different fact. A merge preferring the better-looking value would strip the agency penalty off
//    any show a second source happened to describe more flatteringly.
// 2. `production` and `profile` travel as ONE axis. The classifier derives them together (an agency
//    verdict FORCES weak), so merging them independently would let a row hold an agency production beside
//    a strong profile, a combination the classifier itself can never produce.
//
// Coverage and the reason are not merged at all: `EventClassifier.derived` recomputes them from whatever
// the merge settled on, because a reason is a sentence about the whole classification.
//
// Provenance is per axis, for the same reason the rule is: "may this source correct what is here" is a
// question about the axis that source set, not about the row.
enum GenrePrecedence {

    // The key a row records for whoever set an axis. Sorted and joined so the same set of sources always
    // produces the same key regardless of the order a run reports them in.
    static func sourceKey(_ sourceIds: [String]) -> String {
        sourceIds.sorted().joined(separator: ",")
    }

    // Whether this source may simply overwrite an axis: nothing recorded (every row written before this,
    // plus Prep-created and hand-added ones), or the source that set it coming back to correct itself.
    // A source may always correct its own axis, including back to unreadable.
    static func mayOverwrite(storedKey: String?, incomingKey: String) -> Bool {
        let stored = (storedKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty || stored == incomingKey
    }

    // The genre axis. A genre that was read is never displaced by one that was not; between two genres
    // that were both read, the incumbent stands, so a row never oscillates. That matters beyond tidiness,
    // because a genre picks the GEOGRAPHIC rule (`Discipline.staysInTheBoroughs`), so a genre that flips
    // run to run is a show that appears and disappears from the queue run to run.
    static func mergedDiscipline(stored: Discipline, storedKey: String?,
                                 incoming: Discipline, incomingKey: String) -> Discipline {
        if mayOverwrite(storedKey: storedKey, incomingKey: incomingKey) { return incoming }
        return stored == .other ? incoming : stored
    }

    // The producer axis, production and profile together. `unknown` means nobody could be named, so
    // anything else is more informative; a genuine disagreement between `self` and `agency` leaves the
    // incumbent standing rather than resolving to whichever scores higher.
    static func mergedProducer(stored: (production: Production, profile: Profile), storedKey: String?,
                               incoming: (production: Production, profile: Profile),
                               incomingKey: String) -> (production: Production, profile: Profile) {
        if mayOverwrite(storedKey: storedKey, incomingKey: incomingKey) { return incoming }
        return stored.production == .unknown ? incoming : stored
    }
}
