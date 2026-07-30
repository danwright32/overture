import Testing
@testable import Overture

// #1762: the card says "City not known" for 131 shows whose city the app already holds.
//
// 122 of them are The Green Room 42, a room Overture reads every day, whose rows carry
// `570 10th Ave, New York, NY 10036`. The city is right there in the stored value. The card threw the
// whole string away because one clause starts with a digit, which is the #1030 rule keeping raw street
// addresses off the card. That rule is right; discarding the city with the street number is not.
//
// So the fallback stops asking "is this already clean" and starts asking "what city and state does this
// name", while still never printing a street number.
@Suite("Reading the city out of an address (#1762)")
struct CityFromAddressTests {

    private func line(_ location: String) -> String? {
        VenueDisplay.resolve("Some Unlisted Hall", location: location).location
    }

    // THE MEASURED SET. Every distinct address-shaped `location` value in the live store on 2026-07-29,
    // with the line its card must now show. These are real stored values, not invented shapes: a fixture
    // shaped to make the rule fire would pass forever while proving nothing (L48).
    @Test(arguments: [
        ("570 10th Ave, New York, NY 10036", "New York, NY"),
        ("94 St Marks Pl, New York, NY 10009", "New York, NY"),
        ("466 Grand Street (at Pitt Street), New York, NY 10002", "New York, NY"),
        ("312 West 36th Street, Floor 4, New York, NY, 10018 United States", "New York, NY"),
        ("509 Atlantic Avenue, Brooklyn, NY 11217", "Brooklyn, NY"),
        ("115 MacDougal St #3c, New York, NY 10012, USA", "New York, NY"),
    ])
    func aLiveStoreAddressYieldsItsCityAndState(stored: String, expected: String) {
        #expect(line(stored) == expected)
    }

    // The #1030 promise, which this change must not weaken: Dan's card never shows a raw street address.
    // Asserted as "no digit reaches the output" over the same measured set, so a future loosening that
    // let a house number or a ZIP through goes red.
    @Test(arguments: [
        "570 10th Ave, New York, NY 10036",
        "94 St Marks Pl, New York, NY 10009",
        "466 Grand Street (at Pitt Street), New York, NY 10002",
        "312 West 36th Street, Floor 4, New York, NY, 10018 United States",
        "509 Atlantic Avenue, Brooklyn, NY 11217",
        "115 MacDougal St #3c, New York, NY 10012, USA",
    ])
    func noStreetNumberOrZipEverReachesTheCard(stored: String) {
        let shown = line(stored) ?? ""
        let hasDigit = shown.contains { $0.isNumber }
        #expect(!hasDigit, "\(stored) must not put a digit on the card")
    }

    // Dan's call (2026-07-30): one shape everywhere, so a card reads the same whichever source published
    // the show. A spelled-out state becomes its code rather than being echoed as written.
    @Test func aSpelledOutStateIsShownAsItsCode() {
        #expect(line("157 Montague St, Brooklyn, New York") == "Brooklyn, NY")
    }

    // FAILURE PATH, and the reason this is a rule rather than a guess. An address that names no state
    // gives the card nothing to be sure of, so it says nothing rather than treating the last clause as a
    // city. Both are real live values that used to be shown as nothing and must stay that way.
    @Test(arguments: [
        "44 East 32nd Street, New York City",
        "789 Tenth Avenue, 2nd Floor, NYC, b/t W. 52nd & 53rd Sts.",
    ])
    func anAddressNamingNoStateStillSaysNothing(stored: String) {
        #expect(line(stored) == nil)
    }

    // And an address with a state but no city clause before it has nothing to name either.
    @Test func anAddressWithNoCityClauseSaysNothing() {
        #expect(line("570 10th Ave, NY 10036") == nil)
    }

    // The behaviour this change must NOT break. A location that is already a clean city, with no state at
    // all, is exactly what the fallback was built for and still passes through verbatim. The issue's own
    // write-up suggested "no state means no line", which would have silently dropped this case.
    @Test func anAlreadyCleanLocationStillPassesThroughUnchanged() {
        #expect(line("Brooklyn") == "Brooklyn")
        #expect(line("North Adams, MA") == "North Adams, MA")
    }
}

// #1762 Part 2: the rows the parser cannot reach, because they have no location to read at all.
@Suite("Venues whose city only the table can supply (#1762)")
struct VenueTableGapTests {

    private func location(_ venue: String) -> String? {
        VenueDisplay.resolve(venue, location: nil).location
    }

    // The blank-location venues, spelled EXACTLY as the live store holds them (measured 2026-07-30,
    // status-new rows with a null or empty location). The stored spelling is the whole point: the card
    // looks a venue up exactly, so "House of the Redeemer" matches nothing while the row reads "House of
    // the Redeemer, Fabbri Mansion". An earlier version of this test used the tidy names and passed with
    // an entry that could never fire (L48).
    @Test(arguments: [
        "Roulette",
        "St. Paul's Episcopal Church",
        "Park Avenue Christian Church",
        "Holy Trinity Lutheran Church",
        "Trinity Church NYC",
        "The Kosciuszko Foundation",
        "St. Michael's Parish Hall",
        "St. Luke in the Fields",
        "House of the Redeemer, Fabbri Mansion",
        "Brick Presbyterian Church",
        "The Green Room 42",
    ])
    func aVenueWithNoLocationStillGetsItsCityFromTheTable(venue: String) {
        #expect(location(venue) != nil, "\(venue) should not read as City not known")
    }

    // Blank-location venues that are genuinely NOT in Dan's region. They must stay without a city rather
    // than be given a New York one: an entry here would not merely mislabel them, it would place an
    // out-of-region show IN range and put it in front of him. (Hilton Baltimore is #1799's own subject.)
    @Test(arguments: [
        "Marin Center",
        "Harrogate Convention Centre",
        "Hilton Baltimore BWI Airport",
    ])
    func anOutOfRegionVenueIsNeverGivenANewYorkCity(venue: String) {
        #expect(location(venue) == nil, "\(venue) is not in range and must not be placed in New York")
    }

    // Deliberately still absent. There are two Churches of the Epiphany, and an entry sending it to
    // Washington would hide a real New York show the day one appears. VenuePlaces already records this
    // reasoning; this pins it so a later sweep cannot quietly add the entry.
    @Test func churchOfTheEpiphanyStaysOutOfTheTable() {
        #expect(location("Church of the Epiphany") == nil)
    }

    // The card looks a venue up EXACTLY, so a source appending a word costs the show its city:
    // "Trinity Church NYC" misses the "Trinity Church" the table holds. This one gets its own key.
    //
    // Dan's call (2026-07-30) after the issue's proposed class fix was found not to work: the looser
    // lookup it named tries the whole string, comma clauses, and each side of " at ", none of which
    // "Trinity Church NYC" has, so it misses exactly as the exact lookup does. And the obvious general
    // version, dropping trailing words until something matches, is unsafe here: a trailing word is often
    // a DISAMBIGUATOR ("Holy Trinity Lutheran Church Brooklyn" is not the Manhattan church), so dropping
    // it blind would print the wrong city, which is the hazard VenuePlaces already records for Church of
    // the Epiphany. The class is filed separately.
    @Test func aVenueSpelledWithItsCityAppendedStillGetsACity() {
        #expect(location("Trinity Church NYC") == "New York, NY")
    }

    // The discipline that made the class fix unsafe to rush, pinned: the card resolves a venue exactly,
    // so a room whose name already contains its building never prints that building twice ("Weill Recital
    // Hall at Carnegie Hall, Carnegie Hall"). Any future loosening of the lookup has to keep this true.
    @Test func aRoomNamingItsOwnBuildingNeverPrintsItTwice() {
        let v = VenueDisplay.resolve("Weill Recital Hall at Carnegie Hall", location: nil)
        let carnegies = v.nameLine.components(separatedBy: "Carnegie Hall").count - 1
        #expect(carnegies <= 1, "the building must appear once, not twice: \(v.nameLine)")
    }
}
