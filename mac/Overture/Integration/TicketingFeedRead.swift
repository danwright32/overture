import Foundation

// #1529: reading a source whose own page turned out to be a front for a single-venue ticketing feed.
//
// The Players Theatre is the case. Its schedule page carries no listings a fetch can read, so the scout
// followed its ticket link one hop and landed on OvationTix, whose feed answers with the whole calendar as
// JSON. Overture then synthesized a listings document from that JSON and sent the document it had just
// written to a paid AI read, which is both an odd thing to pay for and a lossy one: the structure was
// already in hand and was thrown away on the way through.
//
// So a page that arrives carrying a feed body is read HERE instead, natively and free, from the same bytes
// the page's hash was taken over (never a second request, which could answer with a different calendar and
// leave the ingested set reconciled against a hash nobody ingested). This mirrors #1295, which did exactly
// this for a TicketTailor widget the same hop lands on.
//
// The venue is the whole difficulty, and it is why this returns events with a nil one so readily. Neither
// feed names a venue anywhere in its data, and the org whose page we left is not an answer: an ensemble's
// ticket link routinely sells for a hall it does not own (the Bargemusic rule). So the room comes from Dan
// (`WatchedSource.venueName`) or it comes from nowhere, and a row with no venue is dropped rather than
// attributed to a guess.
enum TicketingFeedRead {
    // The extractor for a fetched page that came back carrying a ticketing feed, or nil for a page that did
    // not (every ordinary source) or a feed host nothing here can parse.
    static func extractor(for page: FetchedPage, source: WatchedSource,
                          now: Date) -> (any SourceExtractor)? {
        guard let feed = page.ticketingFeedURL.flatMap({ URL(string: $0) }),
              let json = page.ticketingFeedJSON else { return nil }

        // Whose calendar this is. The presenter is never in doubt: it is the source Dan is watching.
        let presenter = source.orgName
        let location = source.venueLocation
        let venue = self.venue(for: page, source: source)

        if OvationTixCalendar.handles(feed) {
            return OvationTixExtractor(
                fetchEvents: { OvationTixCalendar.upcoming(try OvationTixCalendar.parseEvents(json), now: now) },
                presenter: presenter, venue: venue, location: location)
        }
        if VenueTixCalendar.handles(feed) {
            return VenueTixExtractor(
                fetchEvents: { VenueTixCalendar.upcoming(try VenueTixCalendar.parseEvents(json), now: now) },
                presenter: presenter, venue: venue, location: location)
        }
        return nil
    }

    // The room, or nil. Two ways to have one, and both of them are Dan saying so:
    //
    //   - he named it on the row (`venueName`), which is the answer for a source whose own page we had to
    //     leave, since nothing about that page says the shows are in the org's own room;
    //   - he is watching the venue AT ITS OWN TICKETING ADDRESS, no hop involved, which is him pointing at
    //     the room and naming it in the same act.
    //
    // `followedTicketLinkFrom` is what separates those: it is set only when the page Dan is watching had
    // nothing readable on it and we followed its link somewhere else.
    static func venue(for page: FetchedPage, source: WatchedSource) -> String? {
        if let named = source.venueName { return named }
        return page.followedTicketLinkFrom == nil ? source.orgName : nil
    }

    // Whether this row's shows come off a ticketing feed rather than off the page Dan is watching.
    static func readsATicketingFeed(_ source: WatchedSource) -> Bool {
        source.ticketingFeedURL != nil
    }

    // #1588: whether this row has to be asked which room its shows play in. The Sources sheet asks here
    // and nowhere else, and the ask stays (as an Edit) once answered, because a room named wrongly has to
    // be correctable.
    //
    // Two ways to be that row, and the second is the one that was missing. `readsATicketingFeed` alone was
    // the gate, and it reads a field written in ONE branch of ONE scout path: measured against Dan's live
    // store on 2026-08-07, 0 of 73 sources carried it, so the control this gates rendered on nothing at
    // all and the question could not be answered anywhere. Meanwhile a source watched AT a single-venue
    // feed goes through SourceExtractorRegistry, which already reads `venueName ?? orgName`: the answer had
    // a reader the whole time and no way in (L46 the other way round, a field with a reader and no writer).
    //
    // Keyed on the KIND, which every row already carries, rather than on a stamp a particular run may or
    // may not have left.
    static func needsVenueName(_ source: WatchedSource) -> Bool {
        source.kind.isSingleVenue || readsATicketingFeed(source)
    }

    // What is happening to this source's shows while nobody has named the room. The two cases are
    // genuinely different and must not share a sentence: one loses the shows, the other files them under a
    // guess, and telling Dan they were dropped while they sit in the queue in front of him would be the app
    // stating something untrue about what it just did (L11).
    enum UnnamedVenue: Equatable {
        /// Watched at its own single-venue feed: the extractor falls back to the org name as the room.
        case filedUnder(String)
        /// A page we had to leave: the venue resolves to nil and the rows are dropped.
        case keptOutOfTheQueue

        /// Whether this state is actually costing Dan shows. Only that one earns gold on the row; a
        /// plausible default is worth saying and is not a loss.
        var isCostingShows: Bool {
            switch self {
            case .keptOutOfTheQueue: return true
            case .filedUnder: return false
            }
        }
    }

    // The kind decides, because the kind is what picks the extractor: a row can be watched at its own feed
    // AND carry a stamped feed URL from some run, and in that case the fallback-to-org-name path is the one
    // that runs.
    static func whileUnnamed(_ source: WatchedSource) -> UnnamedVenue {
        source.kind.isSingleVenue ? .filedUnder(source.orgName) : .keptOutOfTheQueue
    }
}
