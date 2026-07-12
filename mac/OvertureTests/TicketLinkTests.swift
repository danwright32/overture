import Testing
import Foundation
@testable import Overture

// When a page has nothing readable on it, look at where its LINKS go.
//
// This is Dan's own first lead. secondendingensemble.com is a Wix site whose show page is a poster
// IMAGE and a "BUY TIX HERE" button: there is no text to read even after a browser renders it. But that
// button points at lincolncenter.org, which is perfectly readable and carries the whole listing (Alice
// Tully Hall, the date, "Second Ending Ensemble - Mahler 1 'Titan'").
//
// The information was never on the ensemble's site at all. The link IS the lead. And this is not one
// site's quirk: "a poster and a buy button" is how a great many small ensembles publish a show.
@Suite("Ticket links (#806 follow-up)")
struct TicketLinkTests {
    private let page = URL(string: "https://www.secondendingensemble.com/single-project-1")!

    // Dan's real page, near enough: the only outbound link that means anything is the ticket button.
    @Test func findsTheTicketLinkByItsWords() {
        let html = """
        <div><a href="/">Home</a><a href="/about-us">Our Story</a></div>
        <a href="https://lincolncenter.org/venue/alice-tully-hall/second-ending-ensemble-290">BUY TIX HERE</a>
        <a href="https://www.facebook.com/profile.php?id=426767">Facebook</a>
        <a href="http://wix.com/?utm_campaign=vir_created_with">Wix.com</a>
        """
        let found = TicketLink.candidate(in: html, from: page)
        #expect(found?.host == "lincolncenter.org")
    }

    // "Tickets", "Buy tickets", "Get tickets", "RSVP", "Book now": the same button, a dozen spellings.
    @Test func recognizesTheUsualWordsForABuyButton() {
        for words in ["Tickets", "Buy Tickets", "GET TICKETS", "Book now", "Reserve", "RSVP", "Buy tix"] {
            let html = "<a href=\"https://www.eventbrite.com/e/abc-123\">\(words)</a>"
            #expect(TicketLink.candidate(in: html, from: page)?.host == "www.eventbrite.com",
                    "should have followed a link labelled '\(words)'")
        }
    }

    // ...and a link with no helpful words at all is still a ticket link if it points somewhere that only
    // ever sells tickets. Plenty of sites just show a venue logo.
    @Test func recognizesATicketingOrVenueSiteEvenWithNoWords() {
        let html = "<a href=\"https://www.ticketmaster.com/event/xyz\"><img></a>"
        #expect(TicketLink.candidate(in: html, from: page)?.host == "www.ticketmaster.com")
    }

    // It must never wander off to somewhere useless. A social link is not a lead, and the ORG'S OWN site
    // is the page we just failed to read: following it back would be a loop that solves nothing.
    @Test func ignoresSocialLinksAndTheSiteWeAlreadyCannotRead() {
        let html = """
        <a href="https://www.facebook.com/profile.php?id=426767">Facebook</a>
        <a href="https://www.instagram.com/secondendingensemble/">Instagram</a>
        <a href="https://www.youtube.com/@ianschaefer">YouTube</a>
        <a href="http://wix.com/?utm_campaign=vir_created_with">Wix.com</a>
        <a href="https://www.secondendingensemble.com/about-us">Our Story</a>
        <a href="mailto:info@secondendingensemble.com">Email us</a>
        """
        #expect(TicketLink.candidate(in: html, from: page) == nil)
    }

    // A page with nothing to follow must say so, rather than picking something at random. Reading the
    // WRONG page and presenting it as the lead is worse than admitting we cannot read this one.
    @Test func aPageWithNoTicketLinkYieldsNothing() {
        #expect(TicketLink.candidate(in: "<div>Nothing to book right now.</div>", from: page) == nil)
    }

    // A relative link still works: plenty of sites link their own ticket page. It is on the same site we
    // could not read, so it is NOT a candidate, and pretending otherwise would send us round in a circle.
    @Test func aTicketLinkBackToTheSameUnreadableSiteIsNotAWayOut() {
        let html = "<a href=\"/tickets\">Buy Tickets</a>"
        #expect(TicketLink.candidate(in: html, from: page) == nil)
    }

    // When there are several, the one that SAYS it sells tickets wins over one merely hosted somewhere
    // ticket-ish, because the words are the org's own statement of what the link is for.
    @Test func anExplicitBuyButtonBeatsAMerelyTicketishHost() {
        let html = """
        <a href="https://www.eventbrite.com/o/some-org">Follow us on Eventbrite</a>
        <a href="https://lincolncenter.org/venue/alice-tully-hall/second-ending-ensemble-290">BUY TIX HERE</a>
        """
        #expect(TicketLink.candidate(in: html, from: page)?.host == "lincolncenter.org")
    }
}
