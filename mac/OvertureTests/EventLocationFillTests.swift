import Testing

// #1744. Every venue and title string in this suite is VERBATIM from the live store, taken from the
// untriaged rows that had a blank `location` on 2026-07-29. That matters here more than usual: the
// whole defect is that 342 of 498 untriaged shows reached the queue with no place, so a fixture shaped
// by reasoning rather than measured from those rows would prove nothing about them (L48).
//
// LIVE-STORE-CLAIM verified=2026-07-29 measure="untriaged prospects with a blank `location`, and the venue and title each one carries"
// 342 blank-location untriaged rows, ALL of which name a venue (zero are venue-less), across 78
// distinct venue strings.

@Suite("Filling a show's location: the page's own words first (#1744)")
struct EventLocationFillPrecedenceTests {

    // The page said where it was. Nothing else may speak.
    @Test func thePagesOwnLocationWins() {
        let e = ExtractedEvent(title: "The 2026 Brooklyn Folk Festival", venue: "Jalopy Theatre",
                               location: "Brooklyn")
        #expect(EventLocationFill.location(for: e) == "Brooklyn")
    }

    // A title convention must never overrule a location the page actually published. If it could, a
    // Carnegie row whose page named New York would be moved abroad by its own show name.
    @Test func aTitleConventionNeverOverrulesThePage() {
        let e = ExtractedEvent(title: "NYO Jazz in Beijing, China", venue: "Zankel Hall",
                               location: "New York, NY")
        #expect(EventLocationFill.location(for: e) == "New York, NY")
    }

    // Blank is not a place. The runbook asks for the page's words verbatim, and a page rendering an
    // empty location field must not block the rules below (the same rule SourcePlacement applies).
    @Test func aBlankLocationIsNotAPlaceAndFallsThrough() {
        let e = ExtractedEvent(title: "Songmaking 2026", venue: "Weill Recital Hall", location: "   ")
        #expect(EventLocationFill.location(for: e) == "New York, NY")
    }

    // #2566: rule 1 had no floor under it. This location is verbatim from the live store, and it is the
    // page's whole description of its room: two clauses of directions, a cross street, and a park. The
    // gate reads the "in" that opens the last clause as the state code IN, so this show was in Indiana,
    // and music outside the five boroughs is HIDDEN.
    //
    // A published location that carries a street clause it cannot read a city out of says nothing about
    // where the show is, so it falls through to the rules below rather than being stored.
    @Test func aPublishedLocationThatIsReallyAVenueDescriptionIsRefused() {
        let described = "The Soldiers' and Sailors' Monument, on the North Patio, behind the monument. "
            + "W. 89th St. & Riverside Drive, in Riverside Park"
        #expect(EventLocationFill.location(title: "The Dancing Men: A Sherlock Holmes Mystery",
                                           venue: described, published: described) == nil)
    }

    // The refusal that must NOT happen, and the reason the rule is not simply "refuse an address".
    // Measured 2026-08-16 over every distinct stored location in the live store: 15 of 57 carry a street
    // clause, and 13 of them name their city perfectly well, covering 279 of the 892 placed rows. A rule
    // that refused an address outright would unplace all of them (L93).
    @Test func anAddressShapedPublishedLocationThatNamesItsCityIsKeptVerbatim() {
        for published in ["570 10th Ave, New York, NY 10036",
                          "129 West 67th Street, New York, NY 10023",
                          "315 Columbia St, Brooklyn, New York",
                          "460 Main Street, Chatham NJ",
                          "2 W 64th St, New York, NY, United States",
                          "312 West 36th Street, Floor 4, New York, NY, 10018 United States"] {
            #expect(EventLocationFill.location(title: "A Show", venue: "Weill Recital Hall",
                                               published: published) == published, "\(published)")
        }
    }

    // The other live refusal, which names no state at all rather than the wrong one, and where falling
    // through costs nothing: the card already refuses to print it as a city line (#1030).
    @Test func aPublishedLocationThatIsAVenueNameAndAStreetIsRefused() {
        let described = "The Sanctuary of Brick Presbyterian Church, 1144 Park Avenue"
        #expect(EventLocationFill.location(title: "Cantata Cantata",
                                           venue: described, published: described) == nil)
    }

    // A refused published location must not take the rules below down with it: the fall-through is the
    // whole point of refusing rather than storing.
    @Test func aRefusedPublishedLocationFallsThroughToTheRulesBelow() {
        #expect(EventLocationFill.location(title: "A Show", venue: "Weill Recital Hall",
                                           published: "1144 Park Avenue") == "New York, NY")
    }
}

@Suite("Filling a show's location: reading the venue's own address (#1744)")
struct EventLocationFillVenueAddressTests {

    // The single largest free win: a venue string that already carries its address needs no curated
    // entry at all. All four shapes below are live-store values.
    @Test func readsTheCityAndStateOutOfAnAddressBakedIntoTheVenue() {
        let cases: [(String, String)] = [
            ("Polonsky Shakespeare Center, 262 Ashland Place, Brooklyn, NY 11217", "Brooklyn, NY"),
            ("The Cutting Room, 44 East 32nd Street, New York, NY", "New York, NY"),
            ("The Tank, 312 W 36th St, New York, NY 10018", "New York, NY"),
            ("St. Ann & the Holy Trinity Church, 157 Montague St, Brooklyn, NY", "Brooklyn, NY"),
            ("spit&vigor tiny baby blackbox theater, 115 MacDougal St #3c, New York, NY 10012",
             "New York, NY"),
            ("319 Columbia Street, Brooklyn, NY", "Brooklyn, NY"),
        ]
        for (venue, expected) in cases {
            #expect(EventLocationFill.cityFromVenue(venue) == expected, "\(venue)")
        }
    }

    // The state with no comma before it. VenueNormalization already folds this variance for the natural
    // key; the same shape has to be readable here.
    @Test func readsACityAndStateWithNoCommaBetweenThem() {
        #expect(EventLocationFill.cityFromVenue(
            "Chatham United Methodist Church, 460 Main Street, Chatham NJ") == "Chatham, NJ")
    }

    // A trailing city and state with no street address anywhere in the string.
    @Test func readsATrailingCityAndStateWithNoStreetAddress() {
        let cases: [(String, String)] = [
            ("Jalopy Theatre, Red Hook, Brooklyn, NY", "Brooklyn, NY"),
            ("Greeley Square, New York, NY", "New York, NY"),
            ("Stern Auditorium/Perelman Stage, Carnegie Hall, New York, NY", "New York, NY"),
            ("7 Stages Theatre, Mainstage Theater, Atlanta, GA", "Atlanta, GA"),
            ("Stage West Theatre, Fort Worth, TX", "Fort Worth, TX"),
        ]
        for (venue, expected) in cases {
            #expect(EventLocationFill.cityFromVenue(venue) == expected, "\(venue)")
        }
    }

    // THE REFUSAL. A bare room name names no place, and inventing one is the only failure in this whole
    // area that can hide a real show from Dan. Every one of these is a live-store venue.
    @Test func refusesToInventAPlaceFromABareVenueName() {
        for venue in ["Weill Recital Hall", "Teatro Nacional Eduardo Brito", "Under St Marks",
                      "Asylum NYC", "Church of the Ascension", "Sarah Neuman", nil] {
            #expect(EventLocationFill.cityFromVenue(venue) == nil, "\(venue ?? "nil")")
        }
    }

    // A room number is not a city. "115 MacDougal St #3c" must not read as a place on its own.
    @Test func aStreetClauseAloneIsNotACity() {
        #expect(EventLocationFill.cityFromVenue("115 MacDougal St #3c") == nil)
        #expect(EventLocationFill.cityFromVenue("312 W 36th St") == nil)
    }

    // #2568. THE ROOM'S NAME IS NOT A STATEMENT ABOUT WHERE THE ROOM IS.
    //
    // The first string is verbatim from the live store and is the row the issue was filed on. Nothing in
    // "Canada", "BC" or "Vancouver" anchors a place, so the scan used to reach the first clause and read
    // its last word as a US state, putting a Vancouver show in Georgia. The rest are the same shape with
    // other state words, and they are constructed rather than measured: the live store holds exactly one
    // string of this shape, so a fixture set drawn only from it would pin the one word "Georgia".
    @Test func theVenuesOwnNameNeverNamesAPlace() {
        for venue in ["Rosewood Hotel Georgia, Vancouver, BC, Canada",
                      "Hotel Washington, Vancouver, BC, Canada",
                      "The Indiana, Toronto, ON, Canada",
                      "Hotel Nevada, Havana, Cuba"] {
            #expect(EventLocationFill.cityFromVenue(venue) == nil, "\(venue)")
        }
    }

    // And the consequence, which is the half Dan sees: with the venue string no longer answering wrongly,
    // the curated table gets to answer at all. It has had this room right the whole time.
    @Test func theCuratedTableAnswersARoomTheVenueStringUsedToMisplace() {
        #expect(EventLocationFill.location(title: "Cocktail Hour: The Show",
                                           venue: "Rosewood Hotel Georgia, Vancouver, BC, Canada",
                                           published: nil) == "Vancouver, BC, Canada")
    }

    // The refusal is only of the NAME clause standing alone. A name that is the CITY, with the state
    // written after it, is a shape the store is full of and still reads.
    @Test func aFirstClauseIsStillTheCityWhenALaterClauseNamesTheState() {
        #expect(EventLocationFill.cityFromVenue("New York, NY 10018") == "New York, NY")
        #expect(EventLocationFill.cityFromVenue("Brooklyn, NY") == "Brooklyn, NY")
    }
}

@Suite("Filling a show's location: the tour title convention (#1744)")
struct EventLocationFillTitleTests {

    // docs/contracts.md has said all along that Carnegie's tour titles carry the place and that nothing
    // reads them. These are all seven live rows.
    @Test func readsTheCityAndCountryOutOfATourTitle() {
        let cases: [(String, String)] = [
            ("NYO2 in Santo Domingo, Dominican Republic", "Santo Domingo, Dominican Republic"),
            ("NYO Jazz in Beijing, China", "Beijing, China"),
            ("NYO Jazz in Shanghai, China", "Shanghai, China"),
            ("NYO Jazz in Taichung, Taiwan", "Taichung, Taiwan"),
            ("NYO-USA in Amsterdam, Netherlands", "Amsterdam, Netherlands"),
            ("NYO-USA in Aldeburgh, England", "Aldeburgh, England"),
            ("NYO-USA in Edinburgh, Scotland", "Edinburgh, Scotland"),
        ]
        for (title, expected) in cases {
            #expect(EventLocationFill.cityFromTitle(title) == expected, "\(title)")
        }
    }

    // A US state in the tail is as good as a country, and it is the shape a domestic tour date takes.
    // Both of these are live-store titles.
    @Test func readsAUSStateInTheTail() {
        #expect(EventLocationFill.cityFromTitle("NYO Jazz in San Francisco, California")
                == "San Francisco, California")
        #expect(EventLocationFill.cityFromTitle("NYO-USA in Berlin, Germany") == "Berlin, Germany")
    }

    // THE REFUSAL THAT DOES THE WORK, and the reason this rule is narrow. This title is verbatim from the
    // live store, and it is the shape that gets all the way to the country check: there is a " in ", and
    // the tail after it splits into exactly two comma parts, so every cheaper guard passes it through. The
    // only thing standing between it and a prospect stored as being in a town called `presents "Dead
    // Beat"` is the requirement that the trailing part name a country or state EventPlace recognises.
    //
    // Found by deliberately removing that requirement and looking for which real titles then produced a
    // location (L1): the first draft of this test used titles that all failed an earlier check, so it
    // passed just as happily with the guard deleted and was protecting nothing.
    @Test func refusesATitleWhoseTailParsesButNamesNoPlace() {
        #expect(EventLocationFill.cityFromTitle(
            #"Leigh Bardugo, in conversation with Victor LaValle, presents "Dead Beat""#) == nil)
    }

    // The cheaper refusals, which never reach the country check and are here so the whole shape of the
    // rule is pinned: a tail with no comma, a title with no " in " at all, and a tail that splits into
    // more than two parts. Every one is a live-store title.
    @Test func refusesTitlesThatNeverLookLikeAPlaceAtAll() {
        for title in ["Queeney Todd: The Demon Bottom of Fleet Street in Concert",
                      "United in Song: A Celebration of America",
                      "The Golden Hour Series at Greely Square: Vaden Landers",
                      "Live! on Grand: An LES Talent Show 2026",
                      "ALL FIVE Piano Concertos by Beethoven in Beethoven Roulette!",
                      "Symphony in Motion: Gregg Smith, Igor Stravinsky, & Margaret Bonds",
                      "Estel Vivo Casanovas, saxophone - Washington Debut"] {
            #expect(EventLocationFill.cityFromTitle(title) == nil, "\(title)")
        }
    }
}

@Suite("Filling a show's location: the shared venue table (#1744)")
struct EventLocationFillVenueTableTests {

    // The curated table is the last resort, and it is the SAME table the card's city line reads
    // (VenuePlaces), so a venue can never be in one place for the gate and another for the card.
    @Test func readsTheSharedVenueTable() {
        let cases: [(String, String)] = [
            ("Weill Recital Hall", "New York, NY"),
            ("Zankel Hall", "New York, NY"),
            ("Stern Auditorium / Perelman Stage", "New York, NY"),
            ("Merkin Hall", "New York, NY"),
            ("The Cutting Room", "New York, NY"),
            ("Under St Marks", "New York, NY"),
            ("Jalopy Theatre", "Brooklyn, NY"),
            ("Roulette Intermedium", "Brooklyn, NY"),
            ("National Sawdust", "Brooklyn, NY"),
            ("Teatro Nacional Eduardo Brito", "Santo Domingo, Dominican Republic"),
            ("Usher Hall", "Edinburgh, Scotland"),
            ("Tarrytown Music Hall", "Tarrytown, NY"),
            ("Sarah Neuman", "Mamaroneck, NY"),
            ("The Phillips Collection", "Washington, DC"),
        ]
        for (venue, expected) in cases {
            #expect(EventLocationFill.location(for: ExtractedEvent(title: "A Show", venue: venue))
                    == expected, "\(venue)")
        }
    }

    // A spelling variant of a table venue still resolves, through the SAME fold the natural key and the
    // card already use. All four are live-store spellings of two rooms.
    @Test func aSpellingVariantOfATableVenueStillResolves() {
        for venue in ["Stern Auditorium/Perelman Stage, Carnegie Hall",
                      "Weill Recital Hall at Carnegie Hall",
                      "Zankel Hall at Carnegie Hall",
                      "Merkin Hall at Kaufman Music Center"] {
            #expect(EventLocationFill.location(for: ExtractedEvent(title: "A Show", venue: venue))
                    == "New York, NY", "\(venue)")
        }
    }

    // THE REFUSAL that keeps the whole feature honest: a venue nobody has placed stays unplaced. It is
    // kept and flagged by the gate (#970), never guessed at.
    @Test func aVenueNobodyHasPlacedStaysUnplaced() {
        let e = ExtractedEvent(title: "A Show At Some New Room", venue: "A Room No Table Has Heard Of")
        #expect(EventLocationFill.location(for: e) == nil)
    }

    // An event with no venue and no location at all: still nil, and specifically not a crash.
    @Test func anEventWithNothingToReadIsStillNil() {
        #expect(EventLocationFill.location(for: ExtractedEvent(title: "A Show")) == nil)
    }
}

// #1744. The rules above and the fact that anything USES them are two separate claims, and only the
// second one changes what reaches Dan's queue. Every ingest path (the native feed adapters and the
// agent extract run alike) builds its stored row through ProspectAssembler.decide, so this is the
// assertion that the fill is actually wired into the product rather than sitting in a tested file
// nothing calls.
@Suite("The stored prospect carries the filled location (#1744)")
struct ProspectAssemblerLocationFillTests {

    private func decide(venue: String?, title: String = "A Show",
                        location: String? = nil) -> AssembledProspect? {
        let e = ExtractedEvent(title: title, presenter: "Test Choir", venue: venue,
                               performanceDate: "2026-09-01", sourceUrl: nil, location: location)
        let c = EventClassification(discipline: .music, reachable: true, production: .selfProduced,
                                    profile: .strong, coverage: .likelyUncovered, fitReason: "reason")
        let v = MatchVerdict(relationship: .none, suppressed: false, downbeatClientId: nil,
                             matchedClientName: nil, possible: nil)
        guard case let .prospect(p) = ProspectAssembler.decide(event: e, classification: c, verdict: v) else {
            return nil
        }
        return p
    }

    // The venue table reaches the stored row. Before #1744 this was nil on 342 untriaged shows.
    @Test func aVenueOnlyEventIsStoredWithAPlace() {
        #expect(decide(venue: "Weill Recital Hall")?.location == "New York, NY")
    }

    // And the tour title does too, which is the row Dan was looking at when he asked for this.
    @Test func aTourTitleEventIsStoredWithAPlace() {
        #expect(decide(venue: "Teatro Nacional Eduardo Brito",
                       title: "NYO2 in Santo Domingo, Dominican Republic")?.location
                == "Santo Domingo, Dominican Republic")
    }

    // The page's own words still win all the way through to the store.
    @Test func aPublishedLocationSurvivesUnchanged() {
        #expect(decide(venue: "Weill Recital Hall", location: "Brooklyn")?.location == "Brooklyn")
    }

    // And a room nobody has placed still stores nothing, so the gate keeps and flags it (#970).
    @Test func anUnplaceableEventIsStillStoredWithNothing() {
        #expect(decide(venue: "A Room No Table Has Heard Of")?.location == nil)
    }
}
