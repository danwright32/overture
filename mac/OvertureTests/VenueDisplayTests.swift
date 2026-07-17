import Testing
@testable import Overture

// #342 Phase 1: a curated map enriches known venue names with their parent building and city/state.
// Carnegie's halls are the headline case (the issue's own example); other known NYC venues get a
// location only; unknown venues fall through to the hall name alone.
@Suite("Curated venue display map")
struct VenueDisplayTests {
    @Test func carnegieHallsGetParentAndLocation() {
        for hall in ["Weill Recital Hall", "Zankel Hall", "Stern Auditorium / Perelman Stage"] {
            let v = VenueDisplay.resolve(hall)
            #expect(v.hall == hall)
            #expect(v.parent == "Carnegie Hall")
            #expect(v.location == "New York, NY")
            #expect(v.nameLine == "\(hall), Carnegie Hall")
        }
    }

    @Test func knownNonCarnegieVenueGetsLocationButNoParent() {
        let v = VenueDisplay.resolve("The Metropolitan Museum of Art")
        #expect(v.parent == nil)
        #expect(v.location == "New York, NY")
        #expect(v.nameLine == "The Metropolitan Museum of Art")   // no parent appended
    }

    @Test func unknownVenueFallsThroughToHallOnly() {
        let v = VenueDisplay.resolve("Some Unlisted Hall")
        #expect(v.hall == "Some Unlisted Hall")
        #expect(v.parent == nil)
        #expect(v.location == nil)
        #expect(v.nameLine == "Some Unlisted Hall")
    }

    @Test func missingOrBlankVenueReadsVenueTBD() {
        for raw in [nil, "", "   "] {
            let v = VenueDisplay.resolve(raw)
            #expect(v.hall == "Venue TBD")
            #expect(v.parent == nil)
            #expect(v.location == nil)
        }
    }

    @Test func lookupIgnoresCaseAndExtraWhitespace() {
        let v = VenueDisplay.resolve("  weill   recital  hall ")
        #expect(v.parent == "Carnegie Hall")        // still resolves despite case + spacing
        #expect(v.hall == "  weill   recital  hall ")  // but the original string is preserved for display
    }

    // #1030: Dan's call is city/state only, always, never a raw street address baked into the venue
    // name by whatever source page it came from. These are the real live-store shapes (#1030's own
    // example plus every other comma-address venue found there); every one must lose its street clause
    // and anything after it, while keeping only its own name.
    @Test func aVenueWithABakedInStreetAddressShowsOnlyItsName() {
        let cases: [(String, String)] = [
            ("The Players Theatre, 115 MacDougal Street, New York, NY", "The Players Theatre"),
            ("54 Below, 254 West 54th Street, New York, NY 10019", "54 Below"),
            ("Brick Presbyterian Church, 1140 Park Avenue", "Brick Presbyterian Church"),
            ("Chain Theatre, 312 West 36th Street, Floor 4, New York, NY 10018", "Chain Theatre"),
            ("Park Avenue Christian Church, 1010 Park Avenue", "Park Avenue Christian Church"),
        ]
        for (raw, expected) in cases {
            let v = VenueDisplay.resolve(raw)
            #expect(v.hall == expected, "\(raw) should display as \(expected)")
        }
    }

    // A comma-separated clause that names a real parent building, not a street address, must survive:
    // it has no leading digit, which is the signal a real street-address clause always carries.
    @Test func aRealParentVenueClauseIsKeptNotStripped() {
        #expect(VenueDisplay.resolve("Playhouse Stage, Abrons Arts Center").hall
                == "Playhouse Stage, Abrons Arts Center")
        #expect(VenueDisplay.resolve("Stern Auditorium / Perelman Stage, Carnegie Hall").hall
                == "Stern Auditorium / Perelman Stage, Carnegie Hall")
        // A non-address clause ("Fabbri Mansion") survives; the street clause after it does not.
        #expect(VenueDisplay.resolve("House of the Redeemer, Fabbri Mansion, 7 East 95th Street").hall
                == "House of the Redeemer, Fabbri Mansion")
    }

    // The curated map is still the authority when it has an entry; the event's own `location` (#970)
    // only fills the gap for the long tail of venues the map has never heard of, so most cards get a
    // consistent city/state line instead of an accident of the ~10-entry table.
    @Test func aVenueOutsideTheCuratedMapFallsBackToTheEventsOwnLocation() {
        let v = VenueDisplay.resolve("The Players Theatre, 115 MacDougal Street, New York, NY",
                                     location: "New York, NY")
        #expect(v.hall == "The Players Theatre")
        #expect(v.location == "New York, NY")
    }

    @Test func theCuratedMapsLocationWinsOverTheEventsOwnLocation() {
        let v = VenueDisplay.resolve("The Joyce Theater", location: "Somewhere Else, NY")
        #expect(v.location == "New York, NY")   // curated, not the raw fallback
    }

    @Test func aBlankEventLocationFallsBackToNoLocationNotAnEmptyLine() {
        let v = VenueDisplay.resolve("Some Unlisted Hall", location: "   ")
        #expect(v.location == nil)
    }

    // #1030 follow-up: the runbook explicitly allows `location` to be a full street address (it must
    // be reported verbatim), which would reintroduce the exact "shows a raw address" problem Dan asked
    // to eliminate, just moved to the second line. These are real, live `location` values. None may be
    // used as the fallback; the card should show nothing rather than guess at a city from an address.
    @Test func aStreetAddressLocationIsNeverUsedAsTheFallback() {
        for raw in [
            "123 E 24th St, New York, NY 10010",
            "157 Montague St, Brooklyn, New York",
            "44 East 32nd Street, New York City",
            "466 Grand Street (at Pitt Street), New York, NY 10002",
            "789 Tenth Avenue, 2nd Floor, NYC, b/t W. 52nd & 53rd Sts.",
        ] {
            let v = VenueDisplay.resolve("Some Unlisted Hall", location: raw)
            #expect(v.location == nil, "\(raw) is address-shaped and must not be shown")
        }
    }

    // A location that is already clean city/state shape, with no comma-clause starting with a digit,
    // is exactly what the fallback exists for and must still pass through.
    @Test func aCleanCityStateLocationStillPassesThroughAsTheFallback() {
        #expect(VenueDisplay.resolve("Some Unlisted Hall", location: "Brooklyn").location == "Brooklyn")
        #expect(VenueDisplay.resolve("Some Unlisted Hall", location: "North Adams, MA").location
                == "North Adams, MA")
    }
}
