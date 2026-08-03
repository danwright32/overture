import Testing

// #34: the scout recognized only Carnegie's four named halls, so off-site listings came
// back with no venue (weakening coverage and travel judgments). VenueParser pulls the
// venue out of the listing context: the known halls, a few named off-site venues, and a
// general "proper name + venue word" pattern. Pure, so it's testable (the old logic lived
// in un-testable in-page JS).
@Suite("Venue parser")
struct VenueParserTests {
    @Test func stillRecognizesTheCarnegieHalls() {
        #expect(VenueParser.parse(context: "Brooklyn Youth Chorus at Zankel Hall, 7:30 PM") == "Zankel Hall")
        #expect(VenueParser.parse(context: "…in Stern Auditorium / Perelman Stage tonight") == "Stern Auditorium / Perelman Stage")
    }

    @Test func recognizesNamedOffsiteVenuesByPattern() {
        #expect(VenueParser.parse(context: "A flamenco evening at Thalia Spanish Theatre in Queens") == "Thalia Spanish Theatre")
        #expect(VenueParser.parse(context: "Free concert in Central Park this Saturday") == "Central Park")
        #expect(VenueParser.parse(context: "Evensong at Saint Thomas Church on Fifth Avenue") == "Saint Thomas Church")
    }

    @Test func recognizesKnownVenuesWithoutAVenueWord() {
        #expect(VenueParser.parse(context: "An outdoor recital at Wave Hill") == "Wave Hill")
    }

    @Test func returnsNilWhenNoVenueIsPresent() {
        #expect(VenueParser.parse(context: "Indianapolis Children's Choir spring tour") == nil)
    }
}
