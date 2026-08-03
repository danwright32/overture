import Testing

// #1593 (milestone 32 Phase 0.2): the gate that decides whether one reachability answer may be reused
// across every show from the same presenter. Getting this wrong in the permissive direction is the worst
// LIVE-STORE-CLAIM verified=2026-07-26 measure="the real presenters these cases are drawn from, and whether each is also a venue somewhere in the store"
// outcome the feature can produce: one organisation's contact stamped onto shows it has nothing to do
// with, with nothing on the card to reveal it. So the tests below pin the EXCLUSIONS at least as hard as
// the admissions, on real presenters measured in the live store on 2026-07-26.
@Suite("ProducerGate")
struct ProducerGateTests {

    private func show(_ presenter: String?, at venue: String?) -> ProducerGate.Show {
        ProducerGate.Show(presenter: presenter, venue: venue)
    }

    @Test("a presenter appearing at several venues, never itself a venue, qualifies")
    func multiVenuePresenterQualifies() {
        let shows = [
            show("Tenet Vocal Artists", at: "Church of the Ascension"),
            show("Tenet Vocal Artists", at: "House of the Redeemer"),
        ]
        #expect(ProducerGate.qualifies("Tenet Vocal Artists", among: shows))
    }

    // #1620. Dan, reading the Phase 5 design: "I'm never going to use an @carnegiehall email." He is
    // right, and this test used to assert the opposite. Carnegie Hall Presents is Carnegie Hall
    // presenting in its own building: Stern, Zankel, Weill and Resnick are four rooms inside one house,
    // which the venue-count arm read as a well travelled producer, and the room-name arm let through
    // because the string carries the word "Presents" and so is not spelled like any venue.
    //
    // LIVE-STORE-CLAIM verified=2026-07-28 measure="rows presented by Carnegie Hall Presents"
    // Whichever way the name is dressed, an organisation that carries a venue's name IS that venue, and
    // its address is the house's. 25 rows on the live store, the gate's single biggest admission.
    @Test("a presenter whose name CONTAINS a venue's name is that venue's own brand, and is refused")
    func aVenuesOwnPresentingBrandIsExcluded() {
        let shows = [
            show("Carnegie Hall Presents", at: "Stern Auditorium / Perelman Stage"),
            show("Carnegie Hall Presents", at: "Zankel Hall"),
            show("Carnegie Hall Presents", at: "Bryant Park"),
            // The one row that names the building itself: on the live store it comes from a chorus
            // renting the hall, not from Carnegie's own listing, so the gate has to reach it sideways.
            show("The Masterwork Chorus", at: "Carnegie Hall"),
        ]
        #expect(ProducerGate.qualifies("Carnegie Hall Presents", among: shows) == false)
    }

    // The containment arm must match whole words, or a short venue name would swallow unrelated
    // organisations that merely share a syllable.
    @Test("containment matches a whole venue name, not a fragment of a longer word")
    func containmentDoesNotMatchAFragment() {
        let shows = [
            show("Parkside Chamber Players", at: "Church of the Ascension"),
            show("Parkside Chamber Players", at: "House of the Redeemer"),
            show("Somebody Else", at: "Bryant Park"),
        ]
        #expect(ProducerGate.qualifies("Parkside Chamber Players", among: shows))
    }

    // #1620, the second hole in the same place: one venue spelled two ways counted as two, so a company
    // that only ever plays one room cleared the venue count. Hudson Classical Theater Company plays the
    // Soldiers' and Sailors' Monument, written with and without its leading "the", and nothing else.
    @Test("a parenthetical or a leading 'the' does not make one venue into two")
    func spellingVariantsAreOneVenue() {
        let monument = [
            show("Hudson Classical Theater Company", at: "The Soldiers' and Sailors' Monument"),
            show("Hudson Classical Theater Company", at: "Soldiers' and Sailors' Monument"),
        ]
        #expect(ProducerGate.qualifies("Hudson Classical Theater Company", among: monument) == false)

        let church = [
            show("A Chorus", at: "The Church of St. Mary the Virgin"),
            show("A Chorus", at: "The Church of St. Mary the Virgin (Times Square)"),
        ]
        #expect(ProducerGate.qualifies("A Chorus", among: church) == false)
    }

    // ...and the fold must not go so far that two genuinely different venues merge, which would let a
    // single-room house qualify. Young New Yorkers' Chorus survives on these two real churches.
    @Test("the fold keeps genuinely distinct venues distinct")
    func distinctVenuesSurviveTheFold() {
        let shows = [
            show("Young New Yorkers' Chorus", at: "The Church of St. Mary the Virgin (Times Square)"),
            show("Young New Yorkers' Chorus", at: "The Church of St. Mary the Virgin"),
            show("Young New Yorkers' Chorus", at: "St. Paul's Episcopal Church (Carroll Gardens)"),
            show("Young New Yorkers' Chorus", at: "St. Paul's Episcopal Church"),
        ]
        #expect(ProducerGate.qualifies("Young New Yorkers' Chorus", among: shows))
    }

    // Abrons Arts Center is the case that proves the venue count alone is not enough. In the live store
    // it presents under five different venue spellings, so it sails through the multi-venue arm, and its
    // own name is also a venue on 11 other rows. It is a house, so its answer must never fan out.
    @Test("a presenter whose own name is also a venue never qualifies, however many venues it plays")
    func aPresenterThatIsAlsoAVenueIsExcluded() {
        let shows = [
            show("Abrons Arts Center", at: "Playhouse Stage at Abrons Arts Center"),
            show("Abrons Arts Center", at: "Playhouse Theater, Abrons Arts Center"),
            show("Abrons Arts Center", at: "Abrons Arts Center"),
            show("Some Visiting Company", at: "Abrons Arts Center"),
        ]
        #expect(ProducerGate.qualifies("Abrons Arts Center", among: shows) == false)
    }

    // Nothing in the store separates the Metropolitan Opera (produces its own work) from FRIGID New York
    // (rents its room to 38 companies): both are many different shows at one venue. So the automatic rule
    // excludes both, and Dan promotes the real producers by hand, once each.
    //
    // LIVE-STORE-CLAIM verified=2026-07-29 measure="Metropolitan Opera's presenter, venue and distinct venue count over all 702 prospects"
    // #1719 correction: this fixture used to play the Met at the "Metropolitan Opera House" and its
    // comment claimed the containment arm therefore bit as well. No such venue is in the store. The Met is
    // 7 rows at "Lincoln Center for the Performing Arts", which does NOT contain its name, so on Dan's
    // real data only the VENUE-COUNT arm refuses it and that is what this promotion clears. The invented
    // venue made the test look like it covered more than it did, which is the same defect the FRIGID
    // fixture had; see theRulePromotionClearsAContainmentRefusal below for the arm this no longer covers.
    @Test("Dan can promote a single-venue producer the automatic rule excludes")
    func promotionAdmitsASingleVenueProducer() {
        let shows = [
            show("Metropolitan Opera", at: "Lincoln Center for the Performing Arts"),
            show("Metropolitan Opera", at: "Lincoln Center for the Performing Arts"),
        ]
        #expect(ProducerGate.qualifies("Metropolitan Opera", among: shows) == false)
        #expect(ProducerGate.qualifies("Metropolitan Opera", among: shows,
                                       overrides: .init(promoted: ["metropolitan opera"])))
    }

    // The arm the corrected fixture above no longer reaches, pinned on its own and labelled for what it
    // is: a RULE test, not a live-store one. `isVenueBrand` lets a promotion clear the containment arm on
    // purpose (#1620), and that behaviour has to stay pinned, but it is named here with a made-up pair
    // rather than dressed in a real organisation's name.
    //
    // LIVE-STORE-CLAIM verified=2026-07-29 measure="every presenter whose folded name contains, or is contained by, one of its own venue strings, over all 702 prospects"
    // Measured: EVERY containment case in Dan's store today is a genuine house (54 Below, Jalopy Theatre,
    // The Cutting Room, Abrons Arts Center, SoHo Playhouse, spit&vigor, SFJAZZ, The Players Theatre). Not
    // one of them is an organisation he would promote. So there is no live example to draw this from, and
    // saying so is more useful than borrowing a real name that does not have the shape.
    @Test("as a rule, a promotion clears a containment refusal even with no live case for it")
    func theRulePromotionClearsAContainmentRefusal() {
        let venueKeys: Set<String> = ["example opera house"]
        #expect(ProducerGate.isVenueBrand("example opera", venueKeys: venueKeys))
        #expect(ProducerGate.isVenueBrand("example opera", venueKeys: venueKeys,
                                          overrides: .init(promoted: ["example opera"])) == false)
    }

    // Promotion overrides the venue count ONLY. Dan's standing rule is that a room's own address is never
    // a real contact, so no promotion, mistaken or otherwise, can fan a house's answer across its shows.
    @Test("promotion cannot override the room-name arm")
    func promotionCannotAdmitARoom() {
        let shows = [
            show("The Green Room 42", at: "The Green Room 42"),
            show("The Green Room 42", at: "The Green Room 42, 570 Tenth Ave"),
            show("A Visiting Act", at: "The Green Room 42"),
        ]
        #expect(ProducerGate.qualifies("The Green Room 42", among: shows,
                                       overrides: .init(promoted: ["the green room 42"])) == false)
    }

    // #1763: the test above states a rule the UI had no way to ask about, so the row offered a promotion
    // on every one of those names and the gate silently ignored it.
    //
    // LIVE-STORE-CLAIM verified=2026-07-29 measure="presenters judged the building by the equality arm, and whether promoting each moves the verdict"
    // Measured over the whole store: 15 organisations and 312 rows are refused by equality, and promoting
    // each one leaves all 15 refused. The other 7 brand presenters (39 rows) are caught only by
    // containment, where promotion really does work. This names that difference so a surface can offer
    // the correction where it bites and stay quiet where it cannot.
    @Test("a name spelled exactly like a room is knowable as uncorrectable")
    func aRoomNameIsReportedAsUncorrectable() {
        let shows = [
            show("The Green Room 42", at: "The Green Room 42"),
            show("Carnegie Hall Presents", at: "Carnegie Hall"),
            show("Carnegie Hall Presents", at: "Zankel Hall"),
            show("FRIGID New York", at: "Under St Marks"),
        ]
        let brands = ProducerGate.VenueBrands(shows: shows)

        // Equality: promotion can never reach it, so nothing should offer the correction.
        #expect(brands.isRoomName("The Green Room 42"))
        // Containment only: promotion genuinely relaxes this arm, so the correction must stay.
        #expect(brands.contains("Carnegie Hall Presents"))
        #expect(brands.isRoomName("Carnegie Hall Presents") == false)
        // Not a brand at all, and not a room name either.
        #expect(brands.isRoomName("FRIGID New York") == false)
        #expect(brands.isRoomName(nil) == false)
    }

    // #1719 (milestone 34 Phase 2): the OTHER direction. Promotion says "a producer despite looking like
    // a house"; this says "a house despite not looking like one", and without it the gate has no way to
    // be corrected when every automatic arm misses.
    //
    // LIVE-STORE-CLAIM verified=2026-07-29 measure="FRIGID New York's presenter, venue, distinct venue count, distinct show names and status, over all 702 prospects"
    // FRIGID New York is the measured miss, and the shape below is the store's, not an illustration:
    // 41 rows, 38 distinct shows, 33 of them still untriaged, ALL at a single room, "Under St Marks".
    // It rents that room out, so it is a house in every sense Dan cares about, and its own name appears
    // in no venue string, so neither the equality arm nor the containment arm ever bites.
    //
    // The first version of this test invented a second room ("The Kraine Theater") so the venue-count arm
    // would admit FRIGID and the demote would visibly flip `qualifies`. No such venue exists in the store.
    // That is the trap the frozen fixture below warns about, committed in the same file that warns about
    // it: a sample has to be the rows that make the rule bite, not a shape arranged so it does.
    //
    // What the real single-venue shape means: `qualifies` ALREADY refuses FRIGID, via the venue count, so
    // no reachability answer is being amortised across those 38 companies today. The live miss is the
    // SHARED verdict, `isVenueBrand`, which feeds VenueBrands and so the fuzzy possible-match suppression.
    // Unfixed, one past booking record can raise the same "possible match" question on all 41 rows, which
    // is exactly the #1693 Carnegie Hall shape that hit 18 cards. That is what demoting FRIGID stops.
    @Test("a house the arms miss is not a venue brand until Dan says so")
    func demotionRefusesAHouseTheArmsMiss() {
        let shows = [show("FRIGID New York", at: "Under St Marks")]
        // The miss itself: no arm recognises the room's own operator as the room.
        #expect(ProducerGate.isVenueBrand("frigid new york",
                                          venueKeys: ProducerGate.venueKeys(of: shows)) == false)
        #expect(ProducerGate.isVenueBrand("frigid new york",
                                          venueKeys: ProducerGate.venueKeys(of: shows),
                                          overrides: .init(demoted: ["frigid new york"])))
    }

    // The same verdict through the corpus-wide type the matcher actually reads. HistoryMatch and
    // PossibleMatchRecheck ask VenueBrands, not the gate, so a house Dan named by hand has to reach THIS
    // surface or his correction changes nothing about the question being asked on all 41 rows.
    @Test("a demoted organisation is a venue brand for the shared corpus verdict")
    func demotionReachesVenueBrands() {
        let shows = [show("FRIGID New York", at: "Under St Marks")]
        #expect(ProducerGate.VenueBrands(shows: shows).contains("FRIGID New York") == false)
        #expect(ProducerGate.VenueBrands(shows: shows, overrides: .init(demoted: ["frigid new york"]))
            .contains("FRIGID New York"))
    }

    // On the real single-venue shape the venue count already refuses FRIGID, so a demotion has to be
    // pinned as refusing it for the RIGHT reason. Promotion is the honest control here: it DOES flip a
    // single-venue organisation to qualifying, so the pair below shows the two directions genuinely
    // disagreeing about the same rows rather than both landing on false by accident.
    @Test("demotion refuses where promotion would admit, on the same single-venue corpus")
    func theTwoDirectionsDisagreeOnTheSameCorpus() {
        let shows = [show("FRIGID New York", at: "Under St Marks")]
        #expect(ProducerGate.qualifies("FRIGID New York", among: shows) == false)
        #expect(ProducerGate.qualifies("FRIGID New York", among: shows,
                                       overrides: .init(promoted: ["frigid new york"])))
        #expect(ProducerGate.qualifies("FRIGID New York", among: shows,
                                       overrides: .init(demoted: ["frigid new york"])) == false)
    }

    // Precedence, pinned rather than left to whichever branch happens to run first. The editing layer
    // keeps the two lists mutually exclusive, so this state should never reach the gate from the app;
    // it is pinned anyway because the gate is also called from tests, fixtures and the importer, and
    // because the safe direction is the refusing one (#1593's own rule: fail toward "pay again", never
    // toward a shared answer). Promotion alone admits this corpus (above), so the false below is the
    // demotion winning and not the venue count refusing anyway.
    @Test("a key that is somehow both promoted and demoted is refused")
    func demotionBeatsPromotion() {
        let shows = [show("FRIGID New York", at: "Under St Marks")]
        #expect(ProducerGate.qualifies("FRIGID New York", among: shows,
                                       overrides: .init(promoted: ["frigid new york"],
                                                        demoted: ["frigid new york"])) == false)
    }

    // LIVE-STORE-CLAIM verified=2026-07-27 measure="presenter and venue pairs per organisation, whether the folded presenter name is or contains a folded venue key, and distinct venues per presenter under the gate's own fold, over all 714 prospects"
    // FROZEN FIXTURE. Presenter and venue pairs taken verbatim from Dan's live store, on 2026-07-26 and
    // extended on 2026-07-27 (#1620). These pin behaviour rather than drive it: they exist so a later edit
    // to VenueNormalization or to any arm cannot silently re-admit a room or drop a producer, which is
    // invisible from inside the code and costs real money and real bookings when it goes wrong.
    //
    // #1620 note on why this fixture missed a house for a day: it carried Carnegie Hall Presents WITHOUT
    // any row naming "Carnegie Hall" as a venue, so the shape that makes the containment arm bite was
    // never reproduced here and the gate looked correct. A sample has to include the rows that make the
    // rule bite, not only the rows it already sorts correctly.
    private static let liveStoreSample: [ProducerGate.Show] = [
        // Producers: several genuinely distinct venues, name neither used as nor contained in a venue.
        .init(presenter: "Young Concert Artists", venue: "Merkin Hall"),
        .init(presenter: "Young Concert Artists", venue: "Zankel Hall"),
        .init(presenter: "Tenet Vocal Artists", venue: "St Ann and the Holy Trinity"),
        .init(presenter: "Tenet Vocal Artists", venue: "Church of the Ascension"),
        .init(presenter: "Young New Yorkers' Chorus", venue: "The Church of St. Mary the Virgin"),
        .init(presenter: "Young New Yorkers' Chorus", venue: "The Church of St. Mary the Virgin (Times Square)"),
        .init(presenter: "Young New Yorkers' Chorus", venue: "St. Paul's Episcopal Church (Carroll Gardens)"),

        // #1620 houses presenting under their own brand: the name CONTAINS a venue in the set. Carnegie
        // Hall Presents plays four rooms inside its own building plus the free Citywide programme
        // outdoors, so the venue count reads as a well travelled producer.
        .init(presenter: "Carnegie Hall Presents", venue: "Stern Auditorium / Perelman Stage"),
        .init(presenter: "Carnegie Hall Presents", venue: "Bryant Park"),
        .init(presenter: "Carnegie Hall Presents", venue: "Historic Richmond Town"),
        .init(presenter: "Museum of Chinese in America and Chinese Theatre Works", venue: "Museum of Chinese in America"),
        .init(presenter: "Museum of Chinese in America and Chinese Theatre Works", venue: "Open Door Senior Center"),
        // The only rows on the live store that name the building itself belong to two ensembles renting
        // it. Without these the containment arm has nothing to match, which is how #1620 hid.
        .init(presenter: "The Masterwork Chorus", venue: "Carnegie Hall"),
        .init(presenter: "The Masterwork Chorus", venue: "Chatham United Methodist Church"),
        .init(presenter: "New York Philharmonic", venue: "Carnegie Hall"),
        .init(presenter: "New York Philharmonic", venue: "Wu Tsai Theater"),

        // #1620: one venue spelled two ways. Hudson Classical plays a single monument and nothing else.
        .init(presenter: "Hudson Classical Theater Company", venue: "The Soldiers' and Sailors' Monument"),
        .init(presenter: "Hudson Classical Theater Company", venue: "Soldiers' and Sailors' Monument"),

        // Houses: the name is itself a venue somewhere in the set.
        .init(presenter: "The Green Room 42", venue: "The Green Room 42"),
        .init(presenter: "The Cutting Room", venue: "The Cutting Room"),
        .init(presenter: "Jalopy Theatre", venue: "Jalopy Theatre, Red Hook, Brooklyn, NY"),
        .init(presenter: "Jalopy Theatre", venue: "Jalopy Theatre"),
        .init(presenter: "Merkin Hall", venue: "Merkin Hall"),
        .init(presenter: "SoHo Playhouse", venue: "SoHo Playhouse"),
        .init(presenter: "54 Below", venue: "54 Below, 254 W 54th St. Cellar, NYC 10019"),
        .init(presenter: "54 Below", venue: "54 Below"),
        .init(presenter: "Abrons Arts Center", venue: "Playhouse Stage at Abrons Arts Center"),
        .init(presenter: "Abrons Arts Center", venue: "Abrons Arts Center"),

        // Single-venue presenters. Excluded automatically, promotable by hand. FRIGID rents Under St
        // Marks to 40 different companies; the Met produces its own work. The store cannot tell them
        // apart, which is exactly why neither is admitted without Dan saying so.
        .init(presenter: "FRIGID New York", venue: "Under St Marks"),
        .init(presenter: "Metropolitan Opera", venue: "Metropolitan Opera House"),
        .init(presenter: "DCINY", venue: "Stern Auditorium / Perelman Stage"),
    ]

    @Test("frozen fixture: real producers are admitted", arguments: [
        "Young Concert Artists", "Tenet Vocal Artists", "Young New Yorkers' Chorus",
        "The Masterwork Chorus", "New York Philharmonic",
    ])
    func liveStoreProducersQualify(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample))
    }

    @Test("frozen fixture: houses are never admitted", arguments: [
        "The Green Room 42", "The Cutting Room", "Jalopy Theatre", "Merkin Hall",
        "SoHo Playhouse", "54 Below", "Abrons Arts Center",
        // #1620: a house presenting under its own brand, and a company that plays one room spelled twice.
        "Carnegie Hall Presents", "Museum of Chinese in America and Chinese Theatre Works",
        "Hudson Classical Theater Company",
    ])
    func liveStoreHousesAreExcluded(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample) == false)
    }

    // #1620: an ensemble that RENTS a house keeps its own answer. The Masterwork Chorus plays Carnegie
    // Hall once and its home church four times; the containment arm must read the direction of the
    // relationship, not merely that the two strings appear together.
    @Test("renting a house does not make an ensemble that house")
    func rentingAHouseDoesNotDisqualify() {
        #expect(ProducerGate.qualifies("The Masterwork Chorus", among: Self.liveStoreSample))
        #expect(ProducerGate.qualifies("New York Philharmonic", among: Self.liveStoreSample))
    }

    // The correction that prompted this gate. The plan-council plan shipped a room-name test alone, which
    // admits FRIGID because "FRIGID" is never a venue string, and would have fanned one contact across 40
    // unrelated productions. It stays out unless Dan promotes it.
    @Test("frozen fixture: single-venue presenters stay out until promoted", arguments: [
        "FRIGID New York", "Metropolitan Opera", "DCINY",
    ])
    func liveStoreSingleVenuePresentersAreExcluded(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample) == false)
    }

    @Test("a blank or missing presenter never qualifies", arguments: ["", "   "])
    func blankPresenterNeverQualifies(_ presenter: String) {
        #expect(ProducerGate.qualifies(presenter, among: Self.liveStoreSample) == false)
    }
}
