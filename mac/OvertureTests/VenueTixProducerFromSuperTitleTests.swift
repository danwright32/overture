import Testing
import Foundation

// #2259: The Green Room 42's feed carries the producing company in a structured field, and the ingest
// threw it away, so no amount of searching afterwards could recover it. The card for ICB Productions'
// "Summer Lovin'" read "No email found" while the company was named in the feed's own record for that
// show and its address was three clicks from a search of its bare name.
//
// The old reasoning was half right: most supertitles ARE marketing ("For One Night Only", "Eating
// Everything!"), and keeping them all would pollute the pitchable identity exactly as feared. So the rule
// is not "keep the supertitle", it is "keep it when it is shaped like a producer".
//
// CALIBRATED AGAINST THE LIVE FEED, not invented (L48). Fetched 2026-08-07: 229 events, 174 carrying a
// supertitle, 141 distinct. The first rule tried (a possessive ending OR any of Productions / Company /
// Entertainment / Collective / Theatre / Studio) matched 34 and was plainly wrong on several: it took
// "A Jennings Vocal Studio NYC Cabaret", "Musical Theatre Sung by NYC Teens", "Nova Theatre Series #1"
// and a twelve-word marketing line. Tightened to the rule below it matches 25, and every one of those 25
// reads as a real producer. The strings in this suite are the real ones.
@Suite("The producer named in a VenueTix supertitle (#2259)")
struct VenueTixProducerFromSuperTitleTests {

    // Real producers from the live feed, with what should be stored for each. The trailing possessive is
    // removed: it belongs to the show title that followed it, not to the company's name, and leaving it on
    // would make every later search for this organisation carry a stray apostrophe.
    @Test func aProducerShapedSuperTitleIsKept() {
        let cases: [(String, String)] = [
            ("ICB Productions'", "ICB Productions"),
            ("Underbelly Theatre Company's", "Underbelly Theatre Company"),
            ("New York Theatre Barn's", "New York Theatre Barn"),
            ("Niche Media Productions'", "Niche Media Productions"),
            ("Acting Up Entertainment's", "Acting Up Entertainment"),
            ("Em&Em Productions'", "Em&Em Productions"),
            ("Ted and Togo Productions", "Ted and Togo Productions"),
            ("What\u{2019}s Inside Productions", "What\u{2019}s Inside Productions"),
            // A person producing under their own name is still the producer, and is who Dan pitches.
            ("Ben Cameron's", "Ben Cameron"),
            ("Kelsey Seaman's", "Kelsey Seaman"),
            ("Maggie Wisniewski's", "Maggie Wisniewski"),
        ]
        for (raw, expected) in cases {
            #expect(VenueTixCalendar.producerName(inSuperTitle: raw) == expected,
                    "expected \(raw) to yield \(expected)")
        }
    }

    // A leading connector names the producer after it. Kept because the company really is stated; the
    // connector is not part of its name.
    @Test func aConnectorPrefixIsDroppedAndTheCompanyKept() {
        #expect(VenueTixCalendar.producerName(inSuperTitle: "Hosted by Vivace Arts Collective")
                == "Vivace Arts Collective")
    }

    // Every one of these is a real supertitle from the same feed, and every one is marketing. These are
    // the cases the first rule got wrong, so they are the ones worth pinning: a rule that admits them
    // would put a slogan in the presenter field of a real show and pitch it as an organisation.
    @Test func marketingIsNeverMistakenForAProducer() {
        let marketing = [
            "For One Night Only",
            "Eating Everything!",
            "A Jennings Vocal Studio NYC Cabaret",
            "Musical Theatre Sung by NYC Teens",
            "Nova Theatre Series #1",
            "Featuring Artist of The Dynamic Voice Studio Artists",
            "From Broadway\u{2019}s Original Productions of SIX the Musical and Some Like It Hot",
            "Broadway's Favorite Variety Show",
            "A Benefit for Broadway Cares/Equity Fights AIDS",
            "Celebrating Eleven Years of Music and Stories",
            "Deaf and Hearing Performers in",
            "A Rock Retelling of Macbeth",
        ]
        for line in marketing {
            #expect(VenueTixCalendar.producerName(inSuperTitle: line) == nil,
                    "expected \(line) to be read as marketing, not a producer")
        }
    }

    @Test func nothingAtAllIsNotAProducer() {
        #expect(VenueTixCalendar.producerName(inSuperTitle: nil) == nil)
        #expect(VenueTixCalendar.producerName(inSuperTitle: "   ") == nil)
    }
}

// The wiring, which is a separate claim from the rule (a rule with no wiring is a rule nothing obeys).
@Suite("A named producer becomes the show's presenter (#2259)")
struct VenueTixProducerReachesTheShowTests {

    private func event(_ title: String, superTitle: String?) -> VenueTixCalendar.VTEvent {
        VenueTixCalendar.VTEvent(title: title, superTitle: superTitle, subTitle: nil,
                                 date: Date(timeIntervalSince1970: 1_786_000_000),
                                 eventId: "e-\(title)", seriesId: nil)
    }

    @Test func aShowWithANamedProducerIsAttributedToIt() {
        let events = [event("Summer Lovin'", superTitle: "ICB Productions'")]
        let out = VenueTixCalendar.extractedEvents(from: events, presenter: "The Green Room 42",
                                                   venue: nil, location: nil)
        #expect(out.first?.presenter == "ICB Productions")
    }

    // Everything else still belongs to the room, exactly as before. A rule that quietly re-attributed the
    // whole calendar would be far worse than the gap it closes.
    @Test func aShowWithOnlyMarketingKeepsTheRoom() {
        let events = [event("Broadway Sessions", superTitle: "For One Night Only"),
                      event("Some Cabaret", superTitle: nil)]
        let out = VenueTixCalendar.extractedEvents(from: events, presenter: "The Green Room 42",
                                                   venue: nil, location: nil)
        #expect(out.allSatisfy { $0.presenter == "The Green Room 42" })
    }
}
