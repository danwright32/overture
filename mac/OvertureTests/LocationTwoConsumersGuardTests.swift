import Testing
@testable import Overture

// #1065: the event's `location` string (stored on Prospect, carried on the scout-extract wire) now
// feeds TWO independent consumers with DIFFERENT tolerances, and nothing in the code forces a change
// to one to notice the other:
//
//   1. The GEOGRAPHY GATE  (EventPlace.resolve) reads messier text on purpose: a full street address,
//      a spelled-out state, a foreign country, a region name. Its job is to place a show or say it
//      cannot, so it must keep working on the roughest strings a page publishes.
//   2. The DISPLAY FALLBACK (VenueDisplay.resolve's safeCityStateLine) is stricter: it only shows a
//      `location` on the card when it is ALREADY a clean city/state shape, and REJECTS anything
//      address-shaped rather than reintroduce the raw-address line #1030 removed.
//
// These tolerances have not diverged far enough to justify splitting `location` into two derived
// values (#1065's lighter option), but a future change to how `location` is populated or normalized
// for one consumer could silently change what the other sees. This suite pins BOTH consumers'
// current tolerances against the SAME representative inputs, so such a change turns one of these
// assertions red and forces whoever makes it to reckon with the other consumer.
@Suite("location feeds two consumers with different tolerances (#1065)")
struct LocationTwoConsumersGuardTests {
    // The stricter consumer: what the card would actually show for this `location`, for a venue the
    // curated map has never heard of (the only case where the event's own `location` is consulted).
    private func displayFallback(_ location: String) -> String? {
        VenueDisplay.resolve("Some Unlisted Hall", location: location).location
    }

    // The looser consumer: how the geography gate places this `location`. `.theater` takes Dan's loose
    // rule (anywhere in NY/NJ/CT), so an in-region address lands definitively inRange rather than at a
    // boundary that would make the contrast below ambiguous.
    private func geoVerdict(_ location: String) -> EventPlace.Verdict {
        EventPlace.resolve(location: location, discipline: .theater).verdict
    }

    // AN ADDRESS-SHAPED STRING. This is the crux of #1065. The display fallback must REJECT it (show
    // nothing rather than a raw street line), while the geography gate must still PLACE it (it reads
    // "New York" straight through the street noise and calls it inRange). If someone loosens the
    // display fallback to accept an address, the `== nil` breaks; if someone makes the geography gate
    // choke on an address, the `.inRange` breaks. Either way the divergence surfaces here.
    @Test func anAddressShapedLocationIsRejectedForDisplayButStillPlacedByTheGate() {
        let address = "123 E 24th St, New York, NY 10010"
        #expect(displayFallback(address) == nil)       // stricter: no raw address on the card
        #expect(geoVerdict(address) == .inRange)        // looser: still reads NY and places it
    }

    // A CLEAN CITY/STATE STRING. Both consumers accept it, and they agree: the display fallback shows
    // it verbatim, and the gate places it. This is exactly what the fallback exists for.
    @Test func aCleanCityStateLocationIsShownForDisplayAndPlacedByTheGate() {
        let clean = "Brooklyn, NY"
        #expect(displayFallback(clean) == clean)        // stricter path accepts a clean shape
        #expect(geoVerdict(clean) == .inRange)          // and the gate places it
    }

    // A REGION NAME. This is where the two tolerances genuinely differ today, and pinning that is the
    // point. The geography gate is smart enough to rule "southern Norway" out of range; the display
    // fallback only screens for an address shape, so it passes the region through as the card's line.
    // The two consumers reach OPPOSITE conclusions about the same string, by design, and this test
    // records that so a change collapsing them cannot pass silently.
    @Test func aRegionNameIsPlacedOutOfRangeByTheGateButStillShownForDisplay() {
        let region = "southern Norway"
        #expect(geoVerdict(region) == .outOfRange)      // looser text-handling: a real out-of-range read
        #expect(displayFallback(region) == region)      // stricter-for-addresses only: region passes through
    }
}
