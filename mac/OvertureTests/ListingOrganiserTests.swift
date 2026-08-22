import Testing
import Foundation

// #2259: the listing text the app already hands to the contact run names the producing company, and
// nothing ever read it.
//
// The runbook's `onlyTheActIsNamed` route states as fact that "this listing named no producing
// organisation at all". That is a claim about the PAGE, and the flag behind it measures one much smaller
// thing: whether the stored `presenter` field is empty. On ICB Productions' "Summer Lovin'" the page named
// the company in its own title line, twice over, while the flag said nobody was named, so the run spent
// eleven web calls on two individuals and the card reached Dan reading "No email found".
//
// A rule that lives only in the runbook is a hope (L27), so the app does the reading and hands over the
// answer as data. This is deliberately the NARROW half of the rule: the possessive credit in the listing's
// own title line, which is where a rental room's ticketing page bills its producer. The wider half (a
// founder's own company named in a bio, "presented by" buried in a paragraph) stays a runbook instruction
// for the run, because that text is full of past credits ("produced by Moore Productions", "Jean Doumanian
// Productions (Intern)") that a parse cannot tell from the company putting THIS show on.
//
// MEASURED, not invented (L48): the listing strings below are the real ones, taken from
// `overture-prep-queue.json` as written by the 2026-08-07 prep run.
@Suite("The organisation a listing's title line credits (#2259)")
struct ListingOrganiserTests {

    // The real page text, as the app rendered and stored it.
    private let summerLovin = """
    Events FAQ About Contact Sign in 0 ICB Productions' Summer Lovin' Singing through all the summer \
    feels About the Show Summer Lovin', is a cabaret featuring music of all genres, as we sing through \
    the many feelings of summer.
    """

    @Test func theCompanyCreditedBeforeTheTitleIsFound() {
        #expect(ListingOrganiser.producerNamed(inListingText: summerLovin,
                                               showTitle: "Summer Lovin'",
                                               venue: "The Green Room 42") == "ICB Productions")
    }

    // Page chrome sits immediately before the credit on every one of these ticketing pages ("Events FAQ
    // About Contact Sign in 0"). The walk back has to stop at it, or the company's name arrives with a
    // navigation bar attached to the front of it.
    @Test func pageChromeIsNotPartOfTheName() {
        let name = ListingOrganiser.producerNamed(inListingText: summerLovin,
                                                  showTitle: "Summer Lovin'",
                                                  venue: "The Green Room 42")
        #expect(name?.contains("Sign") == false)
        #expect(name?.contains("0") == false)
    }

    // Real producers billed this way at the same room, each ahead of its own show title.
    @Test func otherRealCreditsAtTheSameRoomAreFound() {
        let cases: [(String, String, String)] = [
            ("Underbelly Theatre Company's Punk Goes Broadway!", "Punk Goes Broadway!",
             "Underbelly Theatre Company"),
            ("New York Theatre Barn's Big Quarterly", "Big Quarterly", "New York Theatre Barn"),
            ("Niche Media Productions' Debuts on Debuts", "Debuts on Debuts", "Niche Media Productions"),
            ("Acting Up Entertainment's The Larry Ray Show", "The Larry Ray Show",
             "Acting Up Entertainment"),
            // A person producing under their own name is still who Dan pitches.
            ("Ilan Rooke's Broadway Sessions", "Broadway Sessions", "Ilan Rooke"),
        ]
        for (text, title, expected) in cases {
            #expect(ListingOrganiser.producerNamed(inListingText: text, showTitle: title,
                                                   venue: "The Green Room 42") == expected,
                    "expected \(text) to credit \(expected)")
        }
    }

    // The room is never the producer, whatever the page says. Overture already refuses a presenter that is
    // only the room's own name (#1787), and this parse must not be the door that lets it back in.
    @Test func theRoomItselfIsNeverTheProducer() {
        #expect(ListingOrganiser.producerNamed(inListingText: "The Green Room 42's Summer Lovin'",
                                               showTitle: "Summer Lovin'",
                                               venue: "The Green Room 42") == nil)
    }

    // A listing that credits nobody must come back with nothing rather than a fragment of its own prose.
    // This is the real text of the fixture built for the route (#1856): the page names two hosts and no
    // company at all.
    @Test func aListingThatNamesNoCompanyYieldsNothing() {
        let text = "Events FAQ About Contact Sign in Broadway's Bad Guys! About the Show An evening of "
            + "musical theatre villains, sung straight and played for keeps."
        #expect(ListingOrganiser.producerNamed(inListingText: text, showTitle: "Broadway's Bad Guys!",
                                               venue: "The Example Room") == nil)
    }

    // The show's title carries its own possessive here, and the words in front of it are prose rather than
    // a credit. Reading "played for keeps" as a company is the failure mode that would put a sentence
    // fragment into a pitch.
    @Test func proseBeforeTheTitleIsNotACredit() {
        let text = "An evening of songs, chosen and played for keeps Summer Lovin' begins at nine."
        #expect(ListingOrganiser.producerNamed(inListingText: text, showTitle: "Summer Lovin'",
                                               venue: "The Green Room 42") == nil)
    }

    // The possessive is the whole signal that these words are a CREDIT rather than the tail of a sentence.
    // Organisation-shaped words alone are not enough in free page text: this page's own prose runs
    // "Tickets from Broadway Productions" straight into the show's name, and a rule that read every
    // company-shaped phrase in front of a title would pitch whoever the sentence happened to mention.
    @Test func companyShapedWordsWithoutAPossessiveAreNotACredit() {
        #expect(ListingOrganiser.producerNamed(
            inListingText: "Tickets from Broadway Productions Summer Lovin' tonight",
            showTitle: "Summer Lovin'", venue: "The Green Room 42") == nil)
    }

    // A possessive that starts lowercase belongs to a sentence, not to a company ("tonight's Summer
    // Lovin'"). Without this the walk back builds "for tonight" and hands it over as an organisation.
    @Test func aLowercasePossessiveIsNotACompany() {
        #expect(ListingOrganiser.producerNamed(inListingText: "Join us for tonight's Summer Lovin' at nine",
                                               showTitle: "Summer Lovin'",
                                               venue: "The Green Room 42") == nil)
    }

    @Test func nothingToReadYieldsNothing() {
        #expect(ListingOrganiser.producerNamed(inListingText: nil, showTitle: "Summer Lovin'",
                                               venue: "The Green Room 42") == nil)
        #expect(ListingOrganiser.producerNamed(inListingText: "   ", showTitle: "Summer Lovin'",
                                               venue: "The Green Room 42") == nil)
        #expect(ListingOrganiser.producerNamed(inListingText: summerLovin, showTitle: "   ",
                                               venue: "The Green Room 42") == nil)
    }

    // A title that never appears in the text (the page is a calendar, or a season index, which is roughly a
    // third of the store's listing URLs) has no title line to read a credit from.
    @Test func aPageThatNeverNamesTheShowYieldsNothing() {
        let text = "August September October November Calendar Plan Your Visit Group Sales Gift Cards"
        #expect(ListingOrganiser.producerNamed(inListingText: text, showTitle: "Summer Lovin'",
                                               venue: "54 Below") == nil)
    }
}
