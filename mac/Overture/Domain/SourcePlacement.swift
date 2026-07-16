import Foundation

// #986: what the Sources sheet says about whether a source names WHERE its shows are.
//
// #970's gate reads exactly one thing: the `location` string the extract run reports per event
// (EventPlace.resolve takes location + Discipline and never sees the venue). No location resolves
// .unknown, which is kept and flagged: the safe answer, and also the answer a source gets when the run has
// silently stopped reporting locations. From the queue those two are identical, and that indistinguishability
// is what cost the entire first #970 plan.
//
// A bare "placed N of M" on every source does NOT detect that, and the live data says why. On 2026-07-16
// FRIGID returned 0 of 43 and that zero was correct: its cards name a venue and no city, and §3a forbids
// guessing one from the org's name. A venue calendar is watched BECAUSE it is a recurring NYC calendar
// (#768/#802), so its shows are in NYC by definition and there is nothing to place. The count would cry
// wolf on ~30 sources, as a third "N of M" line beside SourceYield's and SourceReadability's.
//
// The source's own history is the discriminator instead, and it needs no venue-vs-artist field (SourceKind
// is algolia|html: how a page is read, not what it is). Never placed = a venue calendar. Placed and stopped
// = drift, and loud.
//
// A pure function, never a computation inside the SwiftUI body: a rule computed in a view is a rule no test
// can reach, and two have already drifted here under a green suite (#863, #885).
enum SourcePlacement {

    // The line for Dan, or nothing at all when this source is doing what it has always done. Silence has to
    // mean healthy, or the line is noise he learns to skim.
    static func note(placed: Int, total: Int, hadEverPlaced: Bool) -> String? {
        // A run with nothing in it says nothing about placing. An org between seasons (all_past) or a broken
        // fetch has no shows to place, and the source's health and run note already own that fact. "0 of 0"
        // here would be a second, worse voice for it.
        guard total > 0 else { return nil }

        // THE case (#986). This source has named places before and named none now, so the geographic gate is
        // off for it. Saying only "0 of 4 named a place" would hide the consequence, and the consequence is
        // the part Dan can act on: an out-of-town date now arrives looking exactly like a New York one.
        // Written as ONE literal, never joined from pieces: the copy inventory lists what it finds, and a
        // concatenated sentence lands there as fragments, so the cold read AGENTS.md requires would show
        // half-sentences instead of the line Dan actually reads.
        if hadEverPlaced && placed == 0 {
            return "None of the \(total) shows say where they are, which is new for this source. Until that comes back, Overture can't tell an out-of-town date from a New York one."
        }

        // The baseline. Said once, the first run this source places anything, so a source that has NEVER
        // worked cannot hide among the venue calendars that correctly never place. Without it, silence would
        // cover both.
        if !hadEverPlaced && placed > 0 {
            return "\(placed) of \(total) shows say where they are, so Overture can tell an out-of-town date from a New York one."
        }

        // Everything else is this source being itself: a venue calendar that has never named a city (common,
        // and explicitly not a failure per the runbook's §3a), or an artist page still naming them.
        return nil
    }
}
