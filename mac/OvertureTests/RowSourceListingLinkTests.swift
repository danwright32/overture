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

// Built is not wired (L3). The rule above is a sentence the app never says unless the stages Dan works an
// OPEN PITCH on actually draw it.
@Suite("The stages that work an open pitch actually draw the link (#2816)")
struct RowSourceListingLinkWiringTests {

    private func leadingColumn(ofFunction name: String, in path: String, opening: String) throws -> String {
        let source = SourceGuardHelper.source(path)
        #expect(!source.isEmpty)
        let body = try String(SourceGuard.functionBody(named: name, in: source))
        return try #require(SourceGuardHelper.between(opening, and: "Spacer(minLength: OVSpacing.sm)",
                                                      in: body),
                            "\(name)'s leading column was not found where the guard expects it")
    }

    // The reached-out row: the surface the issue was filed from.
    @Test func theReachedOutRowDrawsTheLink() throws {
        let leading = try leadingColumn(ofFunction: "reachedOutRow", in: "Overture/UI/QueueView.swift",
                                        opening: "VStack(alignment: .leading, spacing: 3) {")
        #expect(leading.contains("RowSourceLink("),
                "the reached-out row no longer offers a way back to the show's own page (#2816)")
    }

    // The one rendering the three surfaces share. Asked HERE rather than of each row, because that is
    // where it lives: a copy per row is how the colour override comes to be on two of them and missing
    // on the third.
    @Test func theSharedLinkAsksTheModelAndOverridesTheLinkColour() {
        let source = SourceGuardHelper.source("Overture/UI/RowSourceLink.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("QueueModel.rowListingLink("),
                "the shared link no longer asks the model what it is linking to, or what to call it")
        // #358: .tint does not recolor a Link's own text on macOS, so without its own override the link
        // ships in bright system blue against the forest and gold palette.
        #expect(source.contains("OVColor.forestText"),
                "the shared link has no colour override, so it draws in system blue (#358)")
    }

    // Decision 2 of #2816's three open questions: the link belongs with the SHOW's own information (the
    // group name and the night it is on), not with the conversation. The audience, the channel line and
    // the proposed-conversation block are all about the conversation, and they follow it.
    @Test func theLinkSitsWithTheShowRatherThanWithTheConversation() throws {
        let leading = try leadingColumn(ofFunction: "reachedOutRow", in: "Overture/UI/QueueView.swift",
                                        opening: "VStack(alignment: .leading, spacing: 3) {")
        let date = try #require(leading.range(of: "ReachedOutRowChrome.showDateLine"))
        let link = try #require(leading.range(of: "RowSourceLink("))
        let conversation = try #require(leading.range(of: "ReplyIdentity.rowAudience"))
        #expect(date.lowerBound < link.lowerBound,
                "the link draws above the show's own date line, splitting the show's own facts")
        #expect(link.lowerBound < conversation.lowerBound,
                "the link draws below the conversation, which is not what it is about (#2816 decision 2)")
    }

    // Decision 3: Follow-ups is the other surface where an open pitch is worked, and BOTH of its rows are
    // covered rather than only the one the issue named (the class, not the instance).
    @Test func bothFollowUpRowsDrawTheLink() throws {
        for (name, opening) in [("row", "VStack(alignment: .leading, spacing: 2) {"),
                                ("postEventRow", "VStack(alignment: .leading, spacing: 3) {")] {
            let leading = try leadingColumn(ofFunction: name, in: "Overture/UI/FollowUpsView.swift",
                                            opening: opening)
            #expect(leading.contains("RowSourceLink("),
                    "FollowUpsView.\(name) offers no way back to the show's own page (#2816)")
        }
    }

    // The label is only as good as the table it is handed, and an EMPTY table makes every row read
    // "Source listing", which is the same silent wrongness #1825 fixed pointing the other way. Both
    // surfaces have to hold a live watchlist query and resolve their rows through it.
    @Test func bothSurfacesResolveTheirLinksAgainstTheLiveWatchlist() {
        for path in ["Overture/UI/QueueView.swift", "Overture/UI/FollowUpsView.swift"] {
            let source = SourceGuardHelper.source(path)
            #expect(source.contains("@Query private var watchedSources: [WatchedSource]"),
                    "\(path) has no live watchlist to resolve a link's label against")
            #expect(source.contains("QueueModel.sourceCalendarIndex(watchedSources)"),
                    "\(path) never builds the calendar table, so every link would read as an event page")
        }
    }
}
