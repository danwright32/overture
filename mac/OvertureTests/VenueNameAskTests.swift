import Testing
import Foundation

// #1588: which rows Overture asks "which room do these shows play in", and what it says is happening
// while nobody has answered.
//
// The ask shipped in #1529 gated on `ticketingFeedURL`, a field written in one branch of one scout path.
// Measured against Dan's live store on 2026-08-07: 0 of 73 watched sources carry it, and 0 carry a venue
// name, so the control rendered on nothing and the question could not be answered anywhere. Meanwhile the
// extractor for a single-venue feed reads `venueName ?? orgName`, so those rows were quietly filing every
// show under the ORGANISATION as its room, which is the guess the Bargemusic rule exists to forbid (they
// play the Boathouse, not the barge) and Dan had no way to correct it.
//
// The two situations are NOT the same and must not share a sentence. A hopped page yields a nil venue and
// the rows are dropped; a source watched at its own feed falls back to the org name and the rows go
// through. Saying "they stay out of the queue" on the second would be the app stating something untrue
// about what it just did (L11).
@Suite("Which rows are asked to name the room (#1588)")
struct VenueNameAskTests {

    private func source(_ kind: SourceKind, org: String = "The Players Theatre",
                        feed: String? = nil, venue: String? = nil) -> WatchedSource {
        let source = WatchedSource(sourceId: "s1", orgName: org,
                                   listingsURL: "https://example.org/calendar", kind: kind)
        source.ticketingFeedURL = feed
        source.venueName = venue
        return source
    }

    // MARK: - Who gets asked

    // Watched AT a single-venue ticketing feed. Nothing in the feed names a room, and the extractor is
    // already reading `venueName` for these kinds, so the answer has somewhere to go.
    @Test func aSourceWatchedAtItsOwnSingleVenueFeedIsAsked() {
        #expect(TicketingFeedRead.needsVenueName(source(.ovationTixFeed)))
        #expect(TicketingFeedRead.needsVenueName(source(.venueTixFeed)))
    }

    // The hop: an ordinary page with nothing readable on it, whose ticket link landed on a feed.
    @Test func aPageWeHadToLeaveIsAsked() {
        #expect(TicketingFeedRead.needsVenueName(source(.html, feed: "https://web.ovationtix.com/trs/cal/277")))
    }

    // Everything else places its shows from what each show itself names, so there is no one room to ask
    // about and the question would be meaningless.
    @Test func anOrdinarySourceIsNotAsked() {
        #expect(TicketingFeedRead.needsVenueName(source(.html)) == false)
        #expect(TicketingFeedRead.needsVenueName(source(.algolia)) == false)
        #expect(TicketingFeedRead.needsVenueName(source(.operaAmericaFeed)) == false)
        #expect(TicketingFeedRead.needsVenueName(source(.squarespaceFeed)) == false)
    }

    // The ask stays once answered, as an Edit: a room named wrongly has to be correctable.
    @Test func theAskRemainsOnARowThatHasAlreadyAnswered() {
        #expect(TicketingFeedRead.needsVenueName(source(.ovationTixFeed, venue: "The Boathouse")))
    }

    // MARK: - What is happening while nobody has answered

    @Test func aSingleVenueFeedFilesItsShowsUnderTheOrganisation() {
        #expect(TicketingFeedRead.whileUnnamed(source(.ovationTixFeed)) == .filedUnder("The Players Theatre"))
    }

    @Test func aHoppedPageKeepsItsShowsOutOfTheQueue() {
        let hopped = source(.html, feed: "https://web.ovationtix.com/trs/cal/277")
        #expect(TicketingFeedRead.whileUnnamed(hopped) == .keptOutOfTheQueue)
    }

    // A source can be both: watched at its own feed AND carrying a stamped feed URL from a run. The KIND
    // decides, because the kind is what picks the extractor, and that extractor falls back to the org name
    // rather than dropping. Getting this precedence backwards would tell Dan his shows were being dropped
    // while they sat in the queue in front of him.
    @Test func theKindDecidesWhenARowLooksLikeBoth() {
        let both = source(.ovationTixFeed, feed: "https://web.ovationtix.com/trs/cal/277")
        #expect(TicketingFeedRead.whileUnnamed(both) == .filedUnder("The Players Theatre"))
    }

    // Only one of the two is costing Dan shows, and only that one earns gold (his rule: gold is for what
    // he can act on, and a plausible default is not the same as a loss).
    @Test func onlyTheDroppedCaseIsLoud() {
        #expect(TicketingFeedRead.UnnamedVenue.keptOutOfTheQueue.isCostingShows)
        #expect(TicketingFeedRead.UnnamedVenue.filedUnder("x").isCostingShows == false)
    }

    // MARK: - What it says

    // Each state says what is actually happening to the shows, and neither tells Dan to do anything: the
    // control beside it is what says that, so the two never say the same thing twice (#843).
    @Test func eachStateStatesItsOwnConsequence() {
        let dropped = VenueNameCopy.promptWhenUnset(.keptOutOfTheQueue)
        let filed = VenueNameCopy.promptWhenUnset(.filedUnder("The Players Theatre"))

        #expect(dropped != filed)
        #expect(dropped.contains("out of the queue"))
        #expect(filed.contains("The Players Theatre"))
        #expect(filed.contains("out of the queue") == false)
    }
}
