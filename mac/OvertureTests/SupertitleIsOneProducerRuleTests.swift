import Testing
import Foundation

// #2452: one question, one answer, across every feed that publishes a credit line above a show's title.
//
// "Does this phrase name the company producing the show, or is it marketing?" was being answered
// separately by each adapter, and the answers disagreed:
//
//   - VenueTix read its supertitle through `ProducerShapedName` and made a producer the presenter (#2259).
//   - OvationTix folded the SAME field into the show's document as a marketing line and left the presenter
//     as the room, so a production naming its producer up front reached Dan with nobody to write to.
//   - TicketTailor named the room unconditionally.
//
// Each file reads as correct on its own, which is exactly why nothing caught the disagreement: two readers
// writing one field are one vocabulary and have to be reconciled against each OTHER, not each against some
// third reference (L89). So these tests are written ACROSS the adapters rather than inside any one of them:
// the same phrase, handed to each reader, has to produce the same verdict.
//
// The strings are the calibrated live ones (VenueTix feed, fetched 2026-08-07: 229 events, 174 carrying a
// supertitle, 141 distinct), not invented shapes, because a fixture shaped to make the rule fire proves
// only that it fires (L48).
@Suite("Every feed reads a supertitle through the one producer rule (#2452)")
struct SupertitleIsOneProducerRuleTests {

    private static let room = "The Green Room 42"

    // Real producers from the live feed, and what each must be stored as.
    private static let producers: [(raw: String, name: String)] = [
        ("ICB Productions'", "ICB Productions"),
        ("Underbelly Theatre Company's", "Underbelly Theatre Company"),
        ("Acting Up Entertainment's", "Acting Up Entertainment"),
        ("Hosted by Vivace Arts Collective", "Vivace Arts Collective"),
        ("Ben Cameron's", "Ben Cameron")
    ]

    // Real supertitles from the same feed, every one of them marketing.
    private static let marketing = [
        "For One Night Only",
        "Eating Everything!",
        "A Jennings Vocal Studio NYC Cabaret",
        "Musical Theatre Sung by NYC Teens",
        "A Rock Retelling of Macbeth"
    ]

    private func venueTixPresenter(_ superTitle: String?) -> String? {
        let event = VenueTixCalendar.VTEvent(title: "Summer Lovin'", superTitle: superTitle, subTitle: nil,
                                             date: Date(timeIntervalSince1970: 1_786_000_000),
                                             eventId: "e1", seriesId: nil)
        return VenueTixCalendar.extractedEvents(from: [event], presenter: Self.room,
                                                venue: nil, location: nil).first?.presenter
    }

    private func ovationTixPresenter(_ superTitle: String?) -> String? {
        let event = OvationTixCalendar.OTEvent(title: "Summer Lovin'", superTitle: superTitle, subTitle: nil,
                                               date: Date(timeIntervalSince1970: 1_786_000_000),
                                               seriesId: nil, productionId: "p1", performanceId: "f1",
                                               startTimes: ["19:00"])
        return OvationTixCalendar.extractedEvents(from: [event], presenter: Self.room,
                                                  venue: nil, location: nil).first?.presenter
    }

    // MARK: - The two feeds that publish a credit line must agree, phrase for phrase

    // The heart of it. Before #2452 this failed on every row: VenueTix answered "ICB Productions" and
    // OvationTix answered "The Green Room 42" about the identical phrase.
    @Test func aProducerShapedSupertitleNamesThePresenterOnEveryFeedThatPublishesOne() {
        for (raw, name) in Self.producers {
            #expect(venueTixPresenter(raw) == name, "VenueTix read \(raw) as something other than \(name)")
            #expect(ovationTixPresenter(raw) == name, "OvationTix read \(raw) as something other than \(name)")
        }
    }

    // The other direction, and the one that keeps the change safe: a marketing line must not become an
    // organisation on EITHER feed. A rule that re-attributed whole calendars to slogans would be far worse
    // than the gap it closes.
    @Test func marketingLeavesTheRoomAsThePresenterOnEveryFeed() {
        for line in Self.marketing {
            #expect(venueTixPresenter(line) == Self.room, "VenueTix pitched the slogan \(line)")
            #expect(ovationTixPresenter(line) == Self.room, "OvationTix pitched the slogan \(line)")
        }
    }

    @Test func noSupertitleAtAllLeavesTheRoomAsThePresenterOnEveryFeed() {
        #expect(venueTixPresenter(nil) == Self.room)
        #expect(ovationTixPresenter(nil) == Self.room)
        // OvationTix publishes an EMPTY supertitle on most rows rather than omitting the key, and the
        // parser already folds "" to nil. Both have to read as "this row credits nobody".
        #expect(ovationTixPresenter("") == Self.room)
        #expect(ovationTixPresenter("   ") == Self.room)
    }

    // MARK: - What the recovered credit does NOT touch

    // The producer becomes the PRESENTER; the show keeps its own name. The supertitle is a credit standing
    // in front of the title, never part of it, and a reader that folded it in would rename the show.
    @Test func theShowKeepsItsOwnTitleWhenItsProducerIsRecovered() {
        let event = OvationTixCalendar.OTEvent(title: "Summer Lovin'", superTitle: "ICB Productions'",
                                               subTitle: nil,
                                               date: Date(timeIntervalSince1970: 1_786_000_000),
                                               seriesId: nil, productionId: "p1", performanceId: "f1",
                                               startTimes: ["19:00"])
        let out = OvationTixCalendar.extractedEvents(from: [event], presenter: Self.room,
                                                     venue: "SoHo Playhouse", location: "New York, NY")
        #expect(out.first?.title == "Summer Lovin'")
        #expect(out.first?.presenter == "ICB Productions")
        #expect(out.first?.venue == "SoHo Playhouse")   // who presents and which room stay two claims (#1529)
        #expect(out.first?.startTimes == ["19:00"])
    }

    // The synthesized document is the PAID read path, and its bytes are what a source's content hash is
    // taken over. Reading the supertitle as a producer must not move a single byte of it, or every
    // OvationTix and VenueTix source would look changed on the next scout and pay for a read it does not
    // need.
    @Test func theSynthesizedDocumentIsUnchangedByTheProducerRule() {
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let ot = [OvationTixCalendar.OTEvent(title: "Summer Lovin'", superTitle: "ICB Productions'",
                                             subTitle: "A cabaret", date: date, seriesId: nil,
                                             productionId: "p1", performanceId: "f1", startTimes: [])]
        #expect(OvationTixCalendar.listingHTML(ot, venueName: Self.room).contains("<p>ICB Productions'</p>"))

        let vt = [VenueTixCalendar.VTEvent(title: "Summer Lovin'", superTitle: "ICB Productions'",
                                           subTitle: "A cabaret", date: date, eventId: "e1", seriesId: nil)]
        #expect(VenueTixCalendar.listingHTML(vt, venueName: Self.room).contains("<p>ICB Productions'</p>"))
    }

    // MARK: - The feed that publishes no credit line at all

    // TicketTailor's widget names one: a series carries series_id, name, venue and event_page_url, and
    // nothing else. It goes through the same rule anyway, handed nothing, so the room's own name still
    // stands. This pins that routing it changed no answer, which is the whole claim for that adapter.
    @Test func aFeedWithNoCreditLineStillNamesTheRoom() {
        let events = [TicketTailorCalendar.TTEvent(name: "Autumn Chamber Concert", venue: nil,
                                                   date: Date(timeIntervalSince1970: 1_786_000_000),
                                                   seriesId: "701", eventURL: "/events/thecell/701")]
        let out = TicketTailorCalendar.extractedEvents(from: events, venueName: "The Cell", location: nil)
        #expect(out.first?.presenter == "The Cell")
        #expect(out.first?.venue == "The Cell")
        #expect(out.first?.title == "Autumn Chamber Concert")
    }

    // And a series that names its own room keeps it, untouched by the producer routing.
    @Test func aFeedWithNoCreditLineKeepsTheRoomItsSeriesNames() {
        let events = [TicketTailorCalendar.TTEvent(name: "Autumn Chamber Concert", venue: "The Cell Theatre",
                                                   date: Date(timeIntervalSince1970: 1_786_000_000),
                                                   seriesId: "701", eventURL: nil)]
        let out = TicketTailorCalendar.extractedEvents(from: events, venueName: "The Cell", location: nil)
        #expect(out.first?.presenter == "The Cell")
        #expect(out.first?.venue == "The Cell Theatre")
    }

    // MARK: - The rule itself, reached by its one name

    // The listing PAGE credits the same companies in front of the same titles, and answers through the same
    // rule (`ListingOrganiser`). Asserted here beside the feeds so the three readings are compared against
    // each other rather than each against the rule in isolation.
    @Test func theListingPageAndTheFeedsAgreeAboutTheSameCompany() {
        let page = "ICB Productions' Summer Lovin' at The Green Room 42"
        #expect(ListingOrganiser.producerNamed(inListingText: page, showTitle: "Summer Lovin'",
                                               venue: Self.room) == "ICB Productions")
        #expect(venueTixPresenter("ICB Productions'") == "ICB Productions")
        #expect(ovationTixPresenter("ICB Productions'") == "ICB Productions")
    }

    // The shared entry point every adapter calls: a credit line names the presenter, anything else falls
    // through to whoever's calendar this is.
    @Test func theSharedEntryPointFallsBackToTheRoomRatherThanToNothing() {
        #expect(ProducerShapedName.presenter(creditedAbove: "ICB Productions'", orElse: Self.room)
                == "ICB Productions")
        #expect(ProducerShapedName.presenter(creditedAbove: "For One Night Only", orElse: Self.room)
                == Self.room)
        #expect(ProducerShapedName.presenter(creditedAbove: nil, orElse: Self.room) == Self.room)
        #expect(ProducerShapedName.presenter(creditedAbove: "", orElse: Self.room) == Self.room)
    }
}
