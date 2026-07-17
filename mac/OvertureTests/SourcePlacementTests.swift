import Testing
import Foundation
@testable import Overture

// #986: counting whether the scout is actually saying WHERE a source's shows are.
//
// #970 gates and scores by geography, and the gate reads one thing: the `location` string the extract run
// reports per event (EventPlace.resolve takes location + Discipline, and never sees the venue). An event
// with no location resolves .unknown and is kept and flagged, which is the safe answer. It is also the
// answer a source gets when the run has silently stopped reporting locations at all, and those two are
// indistinguishable from the queue. That indistinguishability is what cost the entire first #970 plan: the
// council picked a winner whose parser fired on zero rows of the real target, and only a manual page fetch
// caught it. So each run records how many of a source's shows named a place.
//
// #1029 removed the Dan-facing sentence this count used to feed (he did not understand why it mattered),
// but the COUNT stays, recorded on every run for the drift detection above. These tests pin that count.
@Suite("Counting how many of a source's shows say where they are (#986)")
struct SourcePlacementTests {

    // A named place counts. This is the artist page the whole #970 gate is for.
    @Test func aNamedPlaceCounts() {
        #expect(SourcePlacement.placedCount(locations: ["Louisville, KY", "Brooklyn, NY"]) == 2)
    }

    // A missing location does not. This is the venue calendar (FRIGID's shape): its cards name a venue and
    // no city, which is correct and common, not a failure.
    @Test func aMissingLocationDoesNotCount() {
        #expect(SourcePlacement.placedCount(locations: [nil, nil]) == 0)
        #expect(SourcePlacement.placedCount(locations: ["Louisville, KY", nil]) == 1)
    }

    // A blank or whitespace-only string is not a place. The runbook (§3a) asks for the page's words
    // verbatim, and a page that renders an empty location field must not read as one that named somewhere.
    @Test func aBlankOrWhitespaceLocationDoesNotCount() {
        #expect(SourcePlacement.placedCount(locations: ["", "   ", "\n\t"]) == 0)
        #expect(SourcePlacement.placedCount(locations: ["Brooklyn, NY", "  "]) == 1)
    }

    // No shows, no places. A run with nothing in it says nothing about placing.
    @Test func noShowsPlacesNothing() {
        #expect(SourcePlacement.placedCount(locations: []) == 0)
    }
}
