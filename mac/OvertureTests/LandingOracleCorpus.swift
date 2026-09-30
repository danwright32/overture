import Foundation
import SwiftData

// #4328: the synthetic arm of the landing oracle. Every show, presenter, venue and organisation below is
// INVENTED, and every address is on a reserved `.example` domain except the ticketing host whose production
// tokens the token rule reads (venuetix.com, a public vendor, carrying invented tokens). Nothing here may
// ever be replaced by a real name: the real arm exists for that, and it never reaches the repository.
//
// It is built to hold, at least once each, the cases where a landing's answer depends on something other
// than the row in front of it, because those are the cases an incremental rewrite of the landing (A4) gets
// wrong while every per-row test stays green. `LandingOracleTests.theCorpusHoldsEveryCaseTheOracleExistsFor`
// measures each one from the corpus itself, through the app's own functions, so a corpus edit that loses a
// case goes red rather than quietly narrowing what the oracle guards:
//
//   poisoned token      one venuetix token under two folded titles at ONE venue (Harbor Stage)
//   order dependent     a non-transitive title triple on one URL at one venue (Fenwick Chapel): the middle
//                       title matches both ends, the ends do not match each other, so which arrives first
//                       decides whether the URL holds one show or two (ShowLink.addShows, RC2)
//   ambiguous URL       one season page listing two different shows at one venue (Lantern Hall)
//   spelling decision   a source spelling its own room one slip away from how it spelled it before (Marlow)
//   stripped key        a token ambiguous at a venue only STORED rows hold (Quarry Room), arriving in a batch
//                       at a DIFFERENT venue (Delta Loft), which must still be poisoned because the discard
//                       strips the venue (ShowLink.swift:284 to :292, :340 to :345)
@MainActor
enum LandingOracleCorpus {

    // Pinned, so nothing the landing decides from "today" moves with the calendar.
    static let today = "2026-10-05"
    static let now: Date = ISO8601DateFormatter().date(from: "2026-10-05T16:00:00Z")!

    // The named cases, which the shape test reads rather than re-typing them.
    static let poisonedToken = "vtx9001"
    static let poisonedVenue = "Harbor Stage"
    static let ambiguousURL = "https://lanternhall.example/season"
    static let ambiguousVenue = "Lantern Hall"
    static let tripleURL = "https://fenwickchapel.example/winter-light"
    static let tripleVenue = "Fenwick Chapel"
    // No colon: a colon's subtitle is stripped before titles are compared, which would make the ends match.
    static let tripleMiddle = "Winter Light"                 // a prefix of both ends, so it matches both
    static let tripleEnds = ["Winter Light Vespers", "Winter Light Carols"]
    static let spellingSource = "oracle-marlow"
    static let spellingStored = "Marlow Theatre"
    static let spellingIncoming = "Marlow Theater"
    static let strippedToken = "vtx7002"
    static let strippedStoredVenue = "Quarry Room"
    static let strippedBatchVenue = "Delta Loft"

    struct StoredShow {
        let title: String
        let presenter: String
        let venue: String
        let date: String
        let listingURL: String
        var runURLs: [String] = []
        let sourceIds: [String]
    }

    struct Source {
        let id: String
        let org: String
        let listingsURL: String
        let events: [ScoutExtractEvent]
    }

    static func event(_ title: String, _ presenter: String, _ venue: String, _ date: String,
                      _ url: String) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: presenter, venue: venue, performanceDate: date,
                          sourceUrl: url, location: "New York, NY")
    }

    static func vtx(_ token: String, _ slug: String) -> String {
        "https://www.venuetix.com/showdetails/\(token)/\(slug)"
    }

    // The store before the landing.
    static let stored: [StoredShow] = [
        // Harbor: one show this run lists again (an update), one it no longer lists (FeedReconcile's case).
        StoredShow(title: "Tidewater Suite", presenter: "Harbor Stage Collective", venue: "Harbor Stage",
                   date: "2026-10-24", listingURL: "https://harborstage.example/tidewater",
                   sourceIds: ["oracle-harbor"]),
        StoredShow(title: "Old Harbor Revue", presenter: "Harbor Stage Collective", venue: "Harbor Stage",
                   date: "2026-11-14", listingURL: "https://harborstage.example/old-revue",
                   sourceIds: ["oracle-harbor"]),
        // Lantern: a show already on the season page.
        StoredShow(title: "Copper Tide", presenter: "Lantern Hall Players", venue: "Lantern Hall",
                   date: "2026-10-17", listingURL: ambiguousURL, sourceIds: ["oracle-lantern"]),
        StoredShow(title: "Glass Harmonica Night", presenter: "Lantern Hall Players", venue: "Lantern Hall",
                   date: "2026-11-07", listingURL: "https://lanternhall.example/glass-harmonica",
                   sourceIds: ["oracle-lantern"]),
        // Marlow: the source's own spelling of its room, twice.
        StoredShow(title: "The Tin Orchard", presenter: "Marlow Theatre Company", venue: spellingStored,
                   date: "2026-10-22", listingURL: "https://marlowtheatre.example/tin-orchard",
                   sourceIds: [spellingSource]),
        StoredShow(title: "Northbound Letters", presenter: "Marlow Theatre Company", venue: spellingStored,
                   date: "2026-11-12", listingURL: "https://marlowtheatre.example/northbound",
                   sourceIds: [spellingSource]),
        // Quarry: one token under two titles at a room only the store holds.
        StoredShow(title: "Bright Hours", presenter: "Quarry Room Arts", venue: strippedStoredVenue,
                   date: "2026-10-29", listingURL: vtx(strippedToken, "bright-hours"),
                   sourceIds: ["oracle-quarry-archive"]),
        StoredShow(title: "Iron Psalm", presenter: "Quarry Room Arts", venue: strippedStoredVenue,
                   date: "2026-10-30", listingURL: vtx(strippedToken, "iron-psalm"),
                   sourceIds: ["oracle-quarry-archive"]),
        // Rows no source in this run owns, so the landing must leave them exactly as they are.
        StoredShow(title: "Saltmarsh Chorale", presenter: "Saltmarsh Singers", venue: "Pier Nine Room",
                   date: "2026-10-26", listingURL: "https://saltmarsh.example/chorale", sourceIds: []),
        StoredShow(title: "Kite Parade", presenter: "Kestrel Dance Works", venue: "Kestrel Studio",
                   date: "2026-11-03", listingURL: "https://kestrel.example/kite-parade", sourceIds: []),
        StoredShow(title: "Four Small Rooms", presenter: "Hollow Oak Ensemble", venue: "Hollow Oak Barn",
                   date: "2026-11-18", listingURL: "https://hollowoak.example/four-rooms", sourceIds: []),
        StoredShow(title: "Ember Canticles", presenter: "Ember Choir", venue: "Saint Ember Hall",
                   date: "2026-12-02", listingURL: "https://emberchoir.example/canticles", sourceIds: []),
    ]

    // The results file, in the order the landing reads it. The two Fenwick sources are ADJACENT on purpose:
    // swapping them is the seen-to-fail case for the order dependent fold.
    static let sources: [Source] = [
        Source(id: "oracle-harbor", org: "Harbor Stage Collective", listingsURL: "https://harborstage.example/events",
               events: [
                event("Glass Orchard", "Harbor Stage Collective", poisonedVenue, "2026-10-20",
                      vtx(poisonedToken, "glass-orchard")),
                event("Salt Letters", "Harbor Stage Collective", poisonedVenue, "2026-10-21",
                      vtx(poisonedToken, "salt-letters")),
                event("Tidewater Suite", "Harbor Stage Collective", "Harbor Stage", "2026-10-24",
                      "https://harborstage.example/tidewater"),
                event("Paper Lanterns", "Harbor Stage Collective", "Harbor Stage", "2026-10-31",
                      "https://harborstage.example/paper-lanterns"),
                event("The Long Quiet", "Harbor Stage Collective", "Harbor Stage", "2026-11-06",
                      "https://harborstage.example/long-quiet"),
                event("Brass Weather", "Harbor Stage Collective", "Harbor Stage", "2026-11-20",
                      "https://harborstage.example/brass-weather"),
                event("Brass Weather", "Harbor Stage Collective", "Harbor Stage", "2026-11-21",
                      "https://harborstage.example/brass-weather"),
                event("Common Ground Songbook", "Harbor Stage Collective", "Harbor Stage", "2026-12-04",
                      "https://harborstage.example/songbook"),
                event("Driftwood Sonatas", "Harbor Stage Collective", "Harbor Stage", "2026-10-27",
                      "https://harborstage.example/driftwood"),
                event("Lighthouse Keeper's Daughter", "Harbor Stage Collective", "Harbor Stage", "2026-11-10",
                      "https://harborstage.example/lighthouse"),
                event("Undertow", "Harbor Stage Collective", "Harbor Stage", "2026-11-28",
                      "https://harborstage.example/undertow"),
                event("Signal Flags", "Harbor Stage Collective", "Harbor Stage", "2026-12-12",
                      "https://harborstage.example/signal-flags"),
               ]),
        Source(id: "oracle-lantern", org: "Lantern Hall Players", listingsURL: ambiguousURL,
               events: [
                event("Copper Tide", "Lantern Hall Players", ambiguousVenue, "2026-10-17", ambiguousURL),
                event("Night Ferry", "Lantern Hall Players", ambiguousVenue, "2026-10-18", ambiguousURL),
                event("Glass Harmonica Night", "Lantern Hall Players", ambiguousVenue, "2026-11-07",
                      "https://lanternhall.example/glass-harmonica"),
                event("Moth and Candle", "Lantern Hall Players", ambiguousVenue, "2026-11-13",
                      "https://lanternhall.example/moth-candle"),
                event("A Map of Rain", "Lantern Hall Players", ambiguousVenue, "2026-11-27",
                      "https://lanternhall.example/map-of-rain"),
                event("Hearth Songs", "Lantern Hall Players", ambiguousVenue, "2026-12-11",
                      "https://lanternhall.example/hearth-songs"),
                event("The Ninth Lantern", "Lantern Hall Players", ambiguousVenue, "2026-10-24",
                      "https://lanternhall.example/ninth-lantern"),
                event("Coal and Honey", "Lantern Hall Players", ambiguousVenue, "2026-11-01",
                      "https://lanternhall.example/coal-honey"),
                event("Porch Light Stories", "Lantern Hall Players", ambiguousVenue, "2026-11-20",
                      "https://lanternhall.example/porch-light"),
                event("Winter Almanac", "Lantern Hall Players", ambiguousVenue, "2026-12-05",
                      "https://lanternhall.example/winter-almanac"),
               ]),
        Source(id: spellingSource, org: "Marlow Theatre Company", listingsURL: "https://marlowtheatre.example/on-stage",
               events: [
                event("The Tin Orchard", "Marlow Theatre Company", spellingIncoming, "2026-10-22",
                      "https://marlowtheatre.example/tin-orchard"),
                event("Northbound Letters", "Marlow Theatre Company", spellingIncoming, "2026-11-12",
                      "https://marlowtheatre.example/northbound"),
                event("Seven Lamps", "Marlow Theatre Company", spellingIncoming, "2026-10-28",
                      "https://marlowtheatre.example/seven-lamps"),
                event("The Weir Keeper", "Marlow Theatre Company", spellingIncoming, "2026-11-19",
                      "https://marlowtheatre.example/weir-keeper"),
                event("Slow Comet", "Marlow Theatre Company", spellingIncoming, "2026-12-03",
                      "https://marlowtheatre.example/slow-comet"),
                event("Borrowed Summer", "Marlow Theatre Company", spellingIncoming, "2026-10-30",
                      "https://marlowtheatre.example/borrowed-summer"),
                event("A Room Without Clocks", "Marlow Theatre Company", spellingIncoming, "2026-11-05",
                      "https://marlowtheatre.example/no-clocks"),
                event("The Glassblower", "Marlow Theatre Company", spellingIncoming, "2026-11-26",
                      "https://marlowtheatre.example/glassblower"),
                event("Paper Crowns", "Marlow Theatre Company", spellingIncoming, "2026-12-09",
                      "https://marlowtheatre.example/paper-crowns"),
               ]),
        Source(id: "oracle-fenwick-a", org: "Fenwick Chapel Concerts", listingsURL: "https://fenwickchapel.example/a",
               events: [
                event(tripleEnds[0], "Fenwick Chapel Concerts", tripleVenue, "2026-11-02", tripleURL),
                event("Lauds at Dusk", "Fenwick Chapel Concerts", tripleVenue, "2026-10-25",
                      "https://fenwickchapel.example/lauds"),
                event("The Quiet Organ", "Fenwick Chapel Concerts", tripleVenue, "2026-11-22",
                      "https://fenwickchapel.example/quiet-organ"),
                event("Matins for Strings", "Fenwick Chapel Concerts", tripleVenue, "2026-10-31",
                      "https://fenwickchapel.example/matins"),
                event("Plainchant Evening", "Fenwick Chapel Concerts", tripleVenue, "2026-11-08",
                      "https://fenwickchapel.example/plainchant"),
                event("Bells Over Water", "Fenwick Chapel Concerts", tripleVenue, "2026-11-29",
                      "https://fenwickchapel.example/bells-water"),
                event("Organ Marathon", "Fenwick Chapel Concerts", tripleVenue, "2026-12-13",
                      "https://fenwickchapel.example/organ-marathon"),
               ]),
        Source(id: "oracle-fenwick-b", org: "Fenwick Chapel Friends", listingsURL: "https://fenwickchapel.example/b",
               events: [
                event(tripleMiddle, "Fenwick Chapel Friends", tripleVenue, "2026-11-02", tripleURL),
                event("Candlemas Carols", "Fenwick Chapel Friends", tripleVenue, "2026-12-06",
                      "https://fenwickchapel.example/candlemas"),
                event("Vesper Strings", "Fenwick Chapel Friends", tripleVenue, "2026-11-15",
                      "https://fenwickchapel.example/vesper-strings"),
                event("Advent Lessons", "Fenwick Chapel Friends", tripleVenue, "2026-11-30",
                      "https://fenwickchapel.example/advent-lessons"),
                event("Choral Evensong", "Fenwick Chapel Friends", tripleVenue, "2026-11-09",
                      "https://fenwickchapel.example/evensong"),
                event("Recorder Consort", "Fenwick Chapel Friends", tripleVenue, "2026-10-26",
                      "https://fenwickchapel.example/recorder-consort"),
                event("Brass at Twilight", "Fenwick Chapel Friends", tripleVenue, "2026-12-14",
                      "https://fenwickchapel.example/brass-twilight"),
               ]),
        Source(id: "oracle-quarry", org: "Delta Loft Presents", listingsURL: "https://deltaloft.example/calendar",
               events: [
                event(tripleEnds[1], "Delta Loft Presents", tripleVenue, "2026-11-02", tripleURL),
                event("Bright Hours", "Delta Loft Presents", strippedBatchVenue, "2026-10-29",
                      vtx(strippedToken, "bright-hours-loft")),
                event("Rivet and Reed", "Delta Loft Presents", strippedBatchVenue, "2026-10-23",
                      "https://deltaloft.example/rivet-reed"),
                event("Low Tide Radio", "Delta Loft Presents", strippedBatchVenue, "2026-11-09",
                      "https://deltaloft.example/low-tide"),
                event("Gallery of Small Hours", "Delta Loft Presents", strippedBatchVenue, "2026-11-26",
                      "https://deltaloft.example/small-hours"),
                event("Juniper Static", "Delta Loft Presents", strippedBatchVenue, "2026-12-10",
                      "https://deltaloft.example/juniper-static"),
                event("Static Garden", "Delta Loft Presents", strippedBatchVenue, "2026-10-31",
                      "https://deltaloft.example/static-garden"),
                event("Neon Psalter", "Delta Loft Presents", strippedBatchVenue, "2026-11-14",
                      "https://deltaloft.example/neon-psalter"),
                event("Salt Flats Radio Hour", "Delta Loft Presents", strippedBatchVenue, "2026-11-21",
                      "https://deltaloft.example/salt-flats"),
                event("Tape Loop Waltz", "Delta Loft Presents", strippedBatchVenue, "2026-12-12",
                      "https://deltaloft.example/tape-loop"),
               ]),
    ]

    /// The results file the landing reads, with `order` naming the sources to land and in which order.
    static func results(order: [String]? = nil) -> ScoutExtractResults {
        let ids = order ?? sources.map(\.id)
        let byId = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        return ScoutExtractResults(
            version: 1, generatedAt: today + "T12:00:00Z",
            results: ids.compactMap { byId[$0] }.map {
                ScoutExtractResult(sourceId: $0.id, verdict: .upcomingListings, events: $0.events, note: nil)
            })
    }

    /// The store before the landing: every source queued with an unread page, and every stored show.
    static func seed(into context: ModelContext) throws {
        for (i, s) in sources.enumerated() {
            let source = WatchedSource(sourceId: s.id, orgName: s.org, listingsURL: s.listingsURL, kind: .html,
                                       addedAt: now)
            source.pendingContentHash = "oracle-hash-\(i)"
            source.hasUnreadChanges = true
            context.insert(source)
        }
        for show in stored {
            let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: show.title,
                                                                 performanceDate: show.date, venue: show.venue),
                             groupName: show.title, discipline: "music", venue: show.venue,
                             performanceDate: show.date, sourceListingURL: show.listingURL,
                             priorRelationship: "none", production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "invented",
                             matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                             ingestedAt: now, runSourceURLs: show.runURLs)
            p.presenter = show.presenter
            p.sourceIds = show.sourceIds
            context.insert(p)
        }
        try context.save()
    }

    /// One whole landing on a fresh in-memory store: seed, ingest, ONE explicit save, then the container for
    /// a fresh context to read. Autosave is off (TestModelContainer), so that save is the only way in.
    static func land(order: [String]? = nil) async throws -> ModelContainer {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let context = container.mainContext
        try seed(into: context)
        await ScoutExtractIngest.ingest(results(order: order), clients: [], history: [], blocked: .empty,
                                        today: today, now: now, into: context)
        try context.save()
        return container
    }
}
