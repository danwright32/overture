import Testing

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

    // AN ADDRESS-SHAPED STRING. This is the crux of #1065, and #1762 MOVED the stricter consumer's
    // tolerance, which is exactly the event this suite exists to force someone to reckon with.
    //
    // The display fallback now READS an address rather than rejecting it whole, so both consumers get
    // something from this string. They still differ, and the difference is still the point: the gate
    // takes the whole messy value and answers a question about range, while the card takes only the city
    // and state out of it and still puts no street number or ZIP on screen. If a future change lets the
    // card print any part of the street line, the digit assertion breaks; if it makes the gate choke on
    // an address, the `.inRange` breaks.
    @Test func anAddressShapedLocationIsReadForDisplayAndStillPlacedByTheGate() {
        let address = "123 E 24th St, New York, NY 10010"
        let shown = displayFallback(address)
        #expect(shown == "New York, NY")                // stricter: the city and state, never the street
        let hasDigit = (shown ?? "").contains { $0.isNumber }
        #expect(!hasDigit)                              // and #1030's promise survives the loosening
        #expect(geoVerdict(address) == .inRange)        // looser: still reads NY and places it
    }

    // #1762: where the two now genuinely differ on an address. An address naming NO state gives the card
    // nothing it can be sure of, so it says nothing, while the gate still reads the city out of it and
    // places the show. The stricter consumer refusing to guess is the whole distinction.
    @Test func anAddressWithNoStateIsShownAsNothingButStillPlacedByTheGate() {
        let address = "44 East 32nd Street, New York City"
        #expect(displayFallback(address) == nil)
        #expect(geoVerdict(address) == .inRange)
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
