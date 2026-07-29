import Testing
@testable import Overture

// #1720 (milestone 34 Phase 3): the list of houses the app names and hands to the Prep run, so the run
// stops deciding for itself which organisation is the building.
//
// The whole point of computing it HERE is that it is not a new judgment. Every key on the list comes from
// a verdict ProducerGate already reaches (a venue string in the corpus, a presenter its own venue-brand
// arms refuse, or a house Dan demoted by hand), so these tests pin the ASSEMBLY and the naming, and pin
// that the assembly reaches the same answers the gate does. A second copy of the is-this-the-house rule
// written anywhere else, in Swift or in English inside the runbook, is the failure #1702 exists to
// prevent.
//
// LIVE-STORE-CLAIM verified=2026-07-29 measure="whether each organisation below is a venue string, a venue brand, or neither, judged by ProducerGate over the live store's 702 prospects"
// The pairs below were measured on the live store on 2026-07-29 by running the real ProducerGate over the
// whole corpus: 111 distinct venue keys, 21 presenter keys judged venue-brands, 118 keys between them.
@Suite("ProducerGate house list")
struct ProducerHouseListTests {

    private static func show(_ presenter: String?, at venue: String?) -> ProducerGate.Show {
        ProducerGate.Show(presenter: presenter, venue: venue)
    }

    // The Abrons rows as the live store actually holds them on 2026-07-29, plus the one organisation the
    // run named and never visited. This is the #1681 pair, and it is the reason this phase exists.
    private static let abronsCorpus: [ProducerGate.Show] = [
        Self.show("Abrons Arts Center", at: "Abrons Arts Center"),
        Self.show("Abrons Arts Center", at: "Playhouse Theater, Abrons Arts Center"),
        Self.show("Abrons Arts Center", at: "Playhouse Stage at Abrons Arts Center"),
        Self.show("Urban Youth Theater", at: "Abrons Arts Center"),
        Self.show("Emily Johnson and Kai Recollet", at: "Abrons Arts Center"),
    ]

    // The refusing half. Abrons owns the room, so its own inbox stays off the table.
    @Test("a venue string in the corpus is named as a house")
    func aVenueIsAHouse() {
        let keys = Set(ProducerGate.houses(shows: Self.abronsCorpus).map(\.key))
        #expect(keys.contains("abrons arts center"))
    }

    // The following half, and the one that fixes #1681. Henry Street Settlement is named in that show's
    // TITLE, is no venue string anywhere in the live store, and is no venue's brand. Measured
    // 2026-07-29: the gate answers false on both arms. Off the list, so the run must go and look.
    //
    // If this ever flips to true, the run stops visiting henrystreet.org and the bug is back with a
    // green suite over it, which is why it is asserted rather than assumed.
    @Test("an organisation named only in a listing's text is NOT a house")
    func anOrganisationNamedInTheBodyIsNotAHouse() {
        let keys = Set(ProducerGate.houses(shows: Self.abronsCorpus).map(\.key))
        #expect(keys.contains("henry street settlement") == false)
    }

    // #1620's shape: a house presenting under its own brand, which no venue string is ever spelled as.
    // It reaches the list through the gate's containment arm, not through the venue corpus.
    @Test("a venue's own presenting brand is named as a house although no venue is spelled that way")
    func aVenueBrandIsAHouse() {
        let corpus = [
            Self.show("Carnegie Hall Presents", at: "Stern Auditorium / Perelman Stage"),
            Self.show("Carnegie Hall Presents", at: "Bryant Park"),
            Self.show("The Masterwork Chorus", at: "Carnegie Hall"),
        ]
        let houses = ProducerGate.houses(shows: corpus)
        #expect(Set(houses.map(\.key)).contains("carnegie hall presents"))
        // and the ensemble that merely rents the room is not swept up with it
        #expect(Set(houses.map(\.key)).contains("masterwork chorus") == false)
    }

    // Dan's correction on #1719, measured 2026-07-29: FRIGID New York rents Under St Marks to 40
    // companies, but its name is in no venue string, so neither automatic arm reaches it. The demote
    // override is the only thing that makes it a house, and a list that dropped his correction would
    // silently send the run to frigid.org.
    @Test("an organisation Dan demoted by hand is named as a house")
    func aDemotedOrganisationIsAHouse() {
        let corpus = [Self.show("FRIGID New York", at: "Under St Marks")]
        #expect(Set(ProducerGate.houses(shows: corpus).map(\.key)).contains("frigid new york") == false)

        let overrides = ProducerOverrides(demoted: ["frigid new york"])
        let keys = Set(ProducerGate.houses(shows: corpus, overrides: overrides).map(\.key))
        #expect(keys.contains("frigid new york"))
    }

    // Promotion relaxes the containment arm and never the equality arm, exactly as the gate has always
    // held: a presenter spelled precisely like a room IS the room. The list must inherit that split
    // rather than treating any promotion as a blanket exemption.
    @Test("promotion cannot take a name spelled exactly like a room off the list")
    func promotionDoesNotOverrideTheEqualityArm() {
        let corpus = [
            Self.show("Merkin Hall", at: "Merkin Hall"),
            Self.show("Merkin Hall", at: "Kaufman Music Center"),
        ]
        let overrides = ProducerOverrides(promoted: ["merkin hall"])
        let keys = Set(ProducerGate.houses(shows: corpus, overrides: overrides).map(\.key))
        #expect(keys.contains("merkin hall"))
    }

    // A promoted organisation that only ever reached the list through CONTAINMENT does come off it: that
    // is what the promotion is for (the Metropolitan Opera produces its own work at the Metropolitan
    // Opera House), and the gate already draws this line.
    @Test("promotion takes a name off the list when only containment put it there")
    func promotionClearsTheContainmentArm() {
        let corpus = [
            Self.show("Metropolitan Opera", at: "Metropolitan Opera House"),
            Self.show("Metropolitan Opera", at: "Lincoln Center Plaza"),
        ]
        #expect(Set(ProducerGate.houses(shows: corpus).map(\.key)).contains("metropolitan opera"))

        let overrides = ProducerOverrides(promoted: ["metropolitan opera"])
        let keys = Set(ProducerGate.houses(shows: corpus, overrides: overrides).map(\.key))
        #expect(keys.contains("metropolitan opera") == false)
    }

    @Test("no corpus and no corrections names no houses")
    func emptyCorpusYieldsNoHouses() {
        #expect(ProducerGate.houses(shows: []).isEmpty)
    }

    // The readable half of each entry, which is what the run actually compares against a name it read on
    // a page. It is the room's OWN name: a venue string that carries its parent building ("Playhouse
    // Theater, Abrons Arts Center") names the room, and the parent reaches the list on its own rows.
    @Test("each house carries the room's own name, not the spelling that carries its parent")
    func housesCarryAReadableName() {
        let houses = ProducerGate.houses(shows: Self.abronsCorpus)
        let byKey = Dictionary(uniqueKeysWithValues: houses.map { ($0.key, $0.name) })
        #expect(byKey["abrons arts center"] == "Abrons Arts Center")
        #expect(byKey["playhouse theater"] == "Playhouse Theater")
    }

    // Two spellings of one room are one entry, and which spelling is shown cannot depend on the order
    // the corpus happened to arrive in: an unstable list makes two identical runs produce two different
    // queue files, which is noise in every diff and in the fixture comparison.
    @Test("one room spelled several ways is one entry, and the same one whatever the corpus order")
    func oneRoomIsOneStableEntry() {
        let corpus = [
            Self.show("Hudson Classical Theater Company", at: "The Soldiers' and Sailors' Monument"),
            Self.show("Hudson Classical Theater Company", at: "Soldiers' and Sailors' Monument"),
        ]
        let houses = ProducerGate.houses(shows: corpus)
        #expect(houses.filter { $0.key == "soldiers' and sailors' monument" }.count == 1)
        #expect(ProducerGate.houses(shows: corpus.reversed()) == houses)
    }

    @Test("the list is sorted, so the same store always writes the same file")
    func theListIsSorted() {
        let houses = ProducerGate.houses(shows: Self.abronsCorpus)
        #expect(houses.map(\.key) == houses.map(\.key).sorted())
    }

    // A correction Dan made against a store that has since changed: nothing in the corpus folds to his
    // key any more, so there is no spelling to show. Showing the key itself is honest; dropping the
    // entry would silently discard his correction, which is the #1679 failure in a new place.
    @Test("a demoted organisation with no spelling left in the corpus still appears, under its key")
    func aDemotedKeyWithNoSpellingStillAppears() {
        let overrides = ProducerOverrides(demoted: ["frigid new york"])
        let houses = ProducerGate.houses(shows: [], overrides: overrides)
        #expect(houses.map(\.key) == ["frigid new york"])
        #expect(houses.map(\.name) == ["frigid new york"])
    }

    // #1723: a house named ONLY inside a longer venue string. Measured on the live store 2026-07-29:
    // "Kaufman Music Center" appears nowhere on its own, in any field, only inside "Merkin Hall at
    // Kaufman Music Center". So the list carried the whole string and never the building, and a run that
    // read "Kaufman Music Center" on a page was told it was fair game to pitch. Eleven venue strings name
    // a parent this way and four parents were missing from the list because of it.
    @Test("a parent building named inside a venue string is a house in its own right")
    func aParentBuildingInsideAVenueStringIsAHouse() {
        let corpus = [Self.show("Some Ensemble", at: "Merkin Hall at Kaufman Music Center")]
        let houses = ProducerGate.houses(shows: corpus)
        let byKey = Dictionary(uniqueKeysWithValues: houses.map { ($0.key, $0.name) })
        // The room itself, as before.
        #expect(byKey["merkin hall at kaufman music center"] != nil)
        // And the building it sits inside, which is the new part.
        #expect(byKey["kaufman music center"] == "Kaufman Music Center")
    }

    // The same shape with an ADDRESS after "at" rather than a building. "Jalopy's Classroom at 319
    // Columbia St" is on the live store, and turning that tail into a house would put a street address on
    // the list, where it can only ever match wrongly. A leading digit is the same tell VenueNormalization
    // already uses to spot an address clause.
    @Test("an address after \"at\" is not a house")
    func anAddressAfterAtIsNotAHouse() {
        let corpus = [Self.show("Some Ensemble", at: "Jalopy's Classroom at 319 Columbia St")]
        let keys = Set(ProducerGate.houses(shows: corpus).map(\.key))
        #expect(keys.contains("jalopy's classroom at 319 columbia street"))
        #expect(keys.contains { $0.hasPrefix("319") } == false,
                "a street address must never become a house")
    }

    // A parent already on the list contributes nothing new, which is what makes this derivation safe to
    // apply to every venue string rather than a curated few. Both Carnegie rooms name the same building.
    @Test("deriving a parent that is already a house adds no duplicate")
    func aParentAlreadyOnTheListIsNotDuplicated() {
        let corpus = [
            Self.show("Some Ensemble", at: "Weill Recital Hall at Carnegie Hall"),
            Self.show("Another Ensemble", at: "Zankel Hall at Carnegie Hall"),
            Self.show("A Third", at: "Carnegie Hall"),
        ]
        let houses = ProducerGate.houses(shows: corpus)
        #expect(houses.filter { $0.key == "carnegie hall" }.count == 1)
        #expect(houses.map(\.key).contains("carnegie hall"))
    }

    // The gate's own answer and the list must never disagree: anything the list calls a house is
    // something isVenueBrand refuses, and vice versa. This is the assertion that would catch the list
    // growing a judgment of its own.
    @Test("every presenter on the list is one the gate itself refuses")
    func theListAgreesWithTheGate() {
        let corpus = Self.abronsCorpus + [
            Self.show("Carnegie Hall Presents", at: "Bryant Park"),
            Self.show("The Masterwork Chorus", at: "Carnegie Hall"),
            Self.show("FRIGID New York", at: "Under St Marks"),
        ]
        let overrides = ProducerOverrides(demoted: ["frigid new york"])
        let houseKeys = Set(ProducerGate.houses(shows: corpus, overrides: overrides).map(\.key))
        let venueKeys = ProducerGate.venueKeys(of: corpus)
        for presenter in corpus.compactMap({ $0.presenter }) {
            guard let key = ProducerGate.key(presenter) else { continue }
            let gateSaysHouse = ProducerGate.isVenueBrand(key, venueKeys: venueKeys, overrides: overrides)
            #expect(houseKeys.contains(key) == gateSaysHouse,
                    "list and gate disagree about \(presenter)")
        }
    }
}
