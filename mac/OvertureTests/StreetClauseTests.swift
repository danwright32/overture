import Testing
import Foundation

// #2378 and #1852 are one defect asked twice: "is this comma clause a street address, or is it a place?"
//
// #1852: `VenueNormalization.strippingEmbeddedAddress` decided it by "does the clause START WITH A DIGIT",
// which every address clause in the store did when that heuristic was measured. It has since been seen to
// miss, so the #1030 promise that no street address reaches a card was holding by luck of phrasing.
//
// #2378: `EventLocationFill.cityFromVenue` used the same digit test in the other direction, to refuse a
// street as a city. Correct in intent, and it threw away the clause that held the answer:
// `Peter Jay Sharp Theatre, 2537 Broadway at 95th St. New York, NY 10025-6990` names its city in the
// middle of an address clause, because the source wrote no comma between the street and the town.
//
// One test, one vocabulary, both callers.
//
// Every fixture here is a string that is in the live store today, or an exact variant of one, rather than
// a shape invented to make the rule fire (L48). The live-store counts behind them are in
// VenueAddressClauseLiveStoreTests.
@Suite("A street clause is not a place (#2378, #1852)")
struct StreetClauseTests {

    // MARK: - Recognising an address clause

    // The old rule, which still holds: a clause opening with a house number is an address.
    @Test func aClauseStartingWithAHouseNumberIsAnAddress() {
        #expect(StreetClause.isAddress("2537 Broadway at 95th St. New York"))
        #expect(StreetClause.isAddress("254 W 54th St. Cellar"))
        #expect(StreetClause.isAddress("1144 Park Avenue"))
    }

    // #1852's own case, and the one live in the store on 2026-08-12: an address clause that opens with a
    // word. `Sakura Park, W 122nd St & Riverside Dr` printed its whole address on the card.
    @Test func aCrossStreetWithNoHouseNumberIsStillAnAddress() {
        #expect(StreetClause.isAddress("W 122nd St & Riverside Dr"))
        #expect(StreetClause.isAddress("Between 32nd and 33rd Streets"))
        #expect(StreetClause.isAddress("Broadway and 6th Ave"))
        #expect(StreetClause.isAddress("behind the monument. W. 89th St. & Riverside Drive"))
    }

    // The half that matters more, because a wrong answer here CUTS a venue's name off its own card. Each
    // of these is a clause that a live venue string actually keeps today.
    @Test func aParentBuildingOrANeighbourhoodIsNotAnAddress() {
        #expect(!StreetClause.isAddress("Carnegie Hall"))
        #expect(!StreetClause.isAddress("The Morgan Library & Museum"))
        #expect(!StreetClause.isAddress("Red Hook"))
        #expect(!StreetClause.isAddress("Brooklyn"))
        #expect(!StreetClause.isAddress("New York"))
        #expect(!StreetClause.isAddress("NY"))
        #expect(!StreetClause.isAddress("Fabbri Mansion"))
        #expect(!StreetClause.isAddress("Mainstage Theater"))
        #expect(!StreetClause.isAddress("on the North Patio"))
    }

    // A street word has to be a WORD. "Streetcar" and "Placement" are not addresses, and a venue named
    // for one must keep its name.
    @Test func aStreetWordInsideALongerWordIsNotAnAddress() {
        #expect(!StreetClause.isAddress("A Streetcar Named Desire"))
        #expect(!StreetClause.isAddress("The Placement Office"))
        #expect(!StreetClause.isAddress("Driveway Theatre"))
    }

    // MARK: - Reading the city out of an address clause

    // #2378's headline: the town written at the end of a street clause, with no comma before it.
    @Test func theTownAtTheEndOfAStreetClauseIsRead() {
        #expect(StreetClause.trailingPlace("2537 Broadway at 95th St. New York") == "New York")
        #expect(StreetClause.trailingPlace("123 Main St. Brooklyn") == "Brooklyn")
    }

    // A street that names no town answers nothing. This is the failure path #2378 asks for by name: a
    // confidently wrong place is the one failure here that can hide a real show.
    @Test func aStreetWithNoTownAnswersNothing() {
        #expect(StreetClause.trailingPlace("458 West 37 Street @ 10th Avenue") == nil)
        #expect(StreetClause.trailingPlace("458 West 37th Street @10th Avenue") == nil)
        #expect(StreetClause.trailingPlace("250 95th Street") == nil)
        #expect(StreetClause.trailingPlace("1144 Park Avenue") == nil)
        #expect(StreetClause.trailingPlace("312 W 36th St") == nil)
    }

    // The measured near-miss, and the reason the rule is not simply "whatever follows the last street
    // word". `54 Below, 254 W 54th St. Cellar, NYC 10019` is in the store, and its street clause ends in
    // a floor name. One unknown word is not a town.
    @Test func aSingleUnknownWordAfterTheStreetIsNotATown() {
        #expect(StreetClause.trailingPlace("254 W 54th St. Cellar") == nil)
        #expect(StreetClause.trailingPlace("15 Vandam Street Suite") == nil)
    }

    // A single word IS accepted when it names one of the five boroughs, which is a place this codebase
    // already recognises rather than a word this rule decided to trust.
    @Test func aSingleBoroughWordIsATown() {
        #expect(StreetClause.trailingPlace("7 East 95th Street Manhattan") == "Manhattan")
        #expect(StreetClause.trailingPlace("199 Carroll Street Brooklyn") == "Brooklyn")
    }

    // A tail carrying a number is a ZIP or a second street fragment, never a town.
    @Test func aTailWithADigitIsNotATown() {
        #expect(StreetClause.trailingPlace("2537 Broadway at 95th St. 10025") == nil)
        #expect(StreetClause.trailingPlace("254 W 54th St. Suite 3") == nil)
    }
}
