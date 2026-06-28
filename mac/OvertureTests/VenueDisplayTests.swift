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
}
