import Testing
import Foundation

// #2816. Dan, reading a Reached out row: "I'll need to add a source link to this page so I can see the
// source on demand."
//
// Reached out is where he decides what to do about an open pitch, and that decision turns on the SHOW:
// what it is, how long it runs, who else is on the bill, whether the listing has changed since the pitch
// went out. On the triage card the listing is one click away; once the pitch was sent, the same show
// became a title with no way back to its own page. The only web address on the row was the contact
// ROUTE, which is the one place he does not need to go back to.
//
// The rule itself is the CARD's rule, called rather than restated, so one link cannot be described in two
// different words on two screens (#1680, #1825).
@Suite("The show's own link on a row that is not a card (#2816)")
struct RowSourceListingLinkTests {

    // MARK: what the row gets

    // The branch with NO link. A source can leave a show without a listing URL, and a row that answered
    // with something for that case would draw a heading over nothing or a dead control (L45, #1547).
    @Test func aShowWithNoListingGetsNoLinkAtAll() {
        #expect(QueueModel.rowListingLink(listingURL: nil, sourceIds: ["s1"], calendars: [:]) == nil)
        #expect(QueueModel.rowListingLink(listingURL: "", sourceIds: ["s1"], calendars: [:]) == nil)
        #expect(QueueModel.rowListingLink(listingURL: "   ", sourceIds: ["s1"], calendars: [:]) == nil)
    }

    // A per-event page is the show's own page, and it says so. Non-vacuous: the source's calendar is
    // present and populated, so "Source listing" is a verdict about this link rather than the answer an
    // empty table always gives (L48).
    @Test func aPerEventPageIsTheShowsOwnPageAndSaysSo() throws {
        let link = try #require(QueueModel.rowListingLink(
            listingURL: "https://example-hall.example/events/an-evening-of-song",
            sourceIds: ["hall"],
            calendars: ["hall": "https://example-hall.example/events"]))
        #expect(link.label == "Source listing")
        #expect(link.url.absoluteString == "https://example-hall.example/events/an-evening-of-song")
    }

    // The distinction matters MORE here than on triage: a link labelled as the show's own page that lands
    // on a calendar of forty other shows answers none of the questions an open pitch turns on.
    @Test func aLinkThatIsOnlyTheSourcesCalendarSaysSo() throws {
        let link = try #require(QueueModel.rowListingLink(
            listingURL: "https://example-hall.example/whats-on",
            sourceIds: ["hall"],
            calendars: ["hall": "https://example-hall.example/whats-on/"]))
        #expect(link.label == "Venue calendar")
    }

    // Resolved through the row's OWN sources. A show can never inherit a calendar address from a source it
    // was never found on, which would relabel its own event page as somebody else's calendar.
    @Test func acalendarBelongingToAnotherSourceIsNotConsulted() throws {
        let link = try #require(QueueModel.rowListingLink(
            listingURL: "https://example-hall.example/whats-on",
            sourceIds: ["hall"],
            calendars: ["a-different-source": "https://example-hall.example/whats-on"]))
        #expect(link.label == "Source listing")
    }

    // MARK: one rule, not two

    // The label is the CARD's own decision, reached through the same code. Without this the row could grow
    // its own copy of the rule and drift from the card, which is the defect #1825 fixed once already.
    @Test func theLabelIsTheSameAnswerTheQueueCardGives() {
        let calendar = "https://example-hall.example/whats-on"
        for (listing, expected) in [("https://example-hall.example/events/night", "Source listing"),
                                    (calendar, "Venue calendar")] {
            var card = QueueItem(id: "k", groupName: "An Evening of Song", discipline: "music",
                                 venue: "A Hall", performanceDate: "2026-09-12",
                                 sourceListingURL: listing, websiteURL: nil,
                                 priorRelationship: "none", production: "unclear", profile: "unknown",
                                 coverage: "unknown", fitScore: 5, tier: "mid", fitReason: "",
                                 matchedClientName: nil, possibleMatchSource: nil,
                                 possibleMatchName: nil, status: .contacted)
            card.sourceCalendarURLs = [calendar]
            let row = QueueModel.rowListingLink(listingURL: listing, sourceIds: ["hall"],
                                                calendars: ["hall": calendar])
            #expect(row?.label == expected)
            #expect(row?.label == QueueModel.listingLinkLabel(card),
                    "the row and the card described one link in two different words")
        }
    }

    // MARK: the table the label is only as good as

    // A source with no calendar address of its own contributes nothing, rather than an entry pointing at
    // an empty string that every listing would then be compared against.
    @Test func theCalendarTableSkipsASourceThatPublishesNoCalendar() {
        let table = QueueModel.sourceCalendarIndex([
            WatchedSource(sourceId: "hall", orgName: "A Hall",
                          listingsURL: "https://example-hall.example/whats-on", kind: .html),
            WatchedSource(sourceId: "quiet", orgName: "A Quiet Source", listingsURL: nil, kind: .html),
            WatchedSource(sourceId: "blank", orgName: "A Blank Source", listingsURL: "", kind: .html),
        ])
        #expect(table == ["hall": "https://example-hall.example/whats-on"])
    }
}
