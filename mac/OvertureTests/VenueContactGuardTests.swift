import Testing

// #388: a lightweight heuristic backstop for the runbook's own "never the venue" rule (#368). Not
// a full curated venue-to-domain map (that's #342 territory); catches the exact live bug shape: an
// address whose domain matches the venue's own name or its VenueDisplay-resolved parent building.
@Suite("Venue contact guard (#388)")
struct VenueContactGuardTests {
    @Test func aSubHallsParentBuildingDomainIsCaught() {
        // "Weill Recital Hall" resolves (VenueDisplay) to parent "Carnegie Hall"; its own domain
        // is the exact live bug the issue names.
        #expect(VenueContactGuard.looksLikeVenue(email: "publicrelations@carnegiehall.org",
                                                 venue: "Weill Recital Hall") == true)
    }

    @Test func aVenuesOwnNameDomainIsCaughtEvenWithoutAParentEntry() {
        // Not in VenueDisplay's curated map at all; still caught from the raw venue name itself.
        #expect(VenueContactGuard.looksLikeVenue(email: "info@symphonyspace.org",
                                                 venue: "Symphony Space") == true)
    }

    @Test func anUnrelatedDomainIsNotFlagged() {
        #expect(VenueContactGuard.looksLikeVenue(email: "info@auroracollective.example",
                                                 venue: "Weill Recital Hall") == false)
    }

    @Test func aShortGenericVenueNameNeverMatchesEvenACoincidentalDomain() {
        // "Park" alone slugs to 4 characters, below the minimum; must never false-positive on a
        // short, generic venue word.
        #expect(VenueContactGuard.looksLikeVenue(email: "info@park.example", venue: "Park") == false)
    }

    @Test func aNilEmailOrVenueNeverMatches() {
        #expect(VenueContactGuard.looksLikeVenue(email: nil, venue: "Carnegie Hall") == false)
        #expect(VenueContactGuard.looksLikeVenue(email: "info@carnegiehall.org", venue: nil) == false)
        #expect(VenueContactGuard.looksLikeVenue(email: nil, venue: nil) == false)
    }

    @Test func aFormOnlyContactWithNoEmailIsNeverFlagged() {
        #expect(VenueContactGuard.looksLikeVenue(email: "", venue: "Carnegie Hall") == false)
    }
}
