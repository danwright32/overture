import Testing
import Foundation
@testable import Overture

// #986: whether the scout is actually saying WHERE a source's shows are.
//
// #970 gates and scores by geography, and the gate reads one thing: the `location` string the extract run
// reports per event (EventPlace.resolve takes location + Discipline, and never sees the venue). An event
// with no location resolves .unknown and is kept and flagged, which is the safe answer. It is also the
// answer a source gets when the run has silently stopped reporting locations at all, and those two are
// indistinguishable from the queue. That indistinguishability is what cost the entire first #970 plan: the
// council picked a winner whose parser fired on zero rows of the real target, and only a manual page fetch
// caught it.
//
// The obvious detector (a bare "placed N of M" on every source) does not work, and the live data says why.
// Measured on the 2026-07-16 run: FRIGID returned 0 of 43, and that zero is CORRECT. Its event cards name
// a venue ("Under St Marks") and no city anywhere, and the runbook (§3a) forbids guessing a city from the
// org's name ("FRIGID New York"). A venue calendar is on the watchlist BECAUSE it is a recurring NYC
// calendar (#768/#802), so its shows are in NYC by definition and there is nothing to place. A bare count
// would report an alarming zero on ~30 such sources, as a third "N of M" line beside SourceYield's and
// SourceReadability's, which is how all three become furniture Dan skims (see those files' own comments).
//
// So the source's OWN HISTORY is the discriminator, and it needs no venue-vs-artist field (SourceKind is
// algolia|html, which is how a page is read, not what it is). A source that has never named a place is just
// a venue calendar. A source that named places and stopped has drifted, and that is loud. Dan's call
// (2026-07-16): drift, PLUS a one-time baseline the first run that places, so a source that never worked
// from day one cannot hide among the venue calendars.
//
// Computed here, never in the SwiftUI body: a rule computed in a view is a rule no test can reach, and two
// have already drifted here under a green suite (#863, #885).
@Suite("Telling Dan whether a source says where its shows are (#986)")
struct SourcePlacementTests {

    // A venue or org calendar. Its pages name no city, they never have, and that is not a failure: the
    // runbook says a null location is common and explicitly not an error. ~30 of the 38 watched sources are
    // this. If they each carried a line, the line would be furniture.
    @Test func aSourceThatHasNeverNamedAPlaceSaysNothing() {
        #expect(SourcePlacement.note(placed: 0, total: 43, hadEverPlaced: false) == nil)
    }

    // The baseline. The first run that places anything is worth saying once, so a source that has NEVER
    // worked is distinguishable from a venue calendar that correctly never places. Without this, "silent"
    // would cover both.
    @Test func theFirstRunToNameAPlaceSaysSo() {
        let note = SourcePlacement.note(placed: 4, total: 4, hadEverPlaced: false)

        #expect(note == "4 of 4 shows say where they are, so Overture can tell an out-of-town date from a New York one.")
    }

    // THE case, and the failure path this whole issue exists for. A source that placed before and places
    // nothing now has drifted. Saying only "0 of 4 named a place" would hide the consequence, and the
    // consequence is the part Dan can act on: the geographic gate is off for this source, silently.
    @Test func aSourceThatStoppedNamingPlacesSaysWhatThatCosts() {
        let note = SourcePlacement.note(placed: 0, total: 4, hadEverPlaced: true)

        #expect(note == "None of the 4 shows say where they are, which is new for this source. Until that comes back, Overture can't tell an out-of-town date from a New York one.")

    }

    // Steady state. A source that placed before and places now is working. Silence has to mean healthy, or
    // the line is noise, and this is the line that must survive being read.
    @Test func aSourceThatKeepsNamingPlacesSaysNothing() {
        #expect(SourcePlacement.note(placed: 4, total: 4, hadEverPlaced: true) == nil)
    }

    // A partial run is still a working run. The scout reports what a page said, and a page can name a city
    // for some shows and not others; that is the source's shape, not drift.
    @Test func aSourceThatNamesSomePlacesSaysNothing() {
        #expect(SourcePlacement.note(placed: 2, total: 4, hadEverPlaced: true) == nil)
    }

    // An empty run says nothing about placing. A source between seasons (all_past) or one whose fetch broke
    // has no shows to place, and its health and run note already speak for it. Reporting "0 of 0" here would
    // be a second, worse voice for a fact another line already owns.
    @Test func aRunWithNoShowsSaysNothingAboutPlaces() {
        #expect(SourcePlacement.note(placed: 0, total: 0, hadEverPlaced: false) == nil)
        #expect(SourcePlacement.note(placed: 0, total: 0, hadEverPlaced: true) == nil)
    }
}
