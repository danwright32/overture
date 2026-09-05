import Foundation

// #2365: does this show get the ordinary lead time window, or a past client's longer one?
//
// DAN'S RULE, 2026-08-11, in his words: "90 days for anything that isn't a past client. and then the
// extended check for past clients. we should show everything in scout from those two groups, don't hide
// anything." And, on the other end of the pipeline: "Scout should be solely responsible for filtering
// out based on how far away it is. If it gets to prep I want to be able to prep it."
//
// The NUMBER in the first sentence was superseded on 2026-08-31 (#3423): the ordinary arm is nine weeks
// now, not 90 days. His words are kept verbatim rather than edited, because they are the record of the
// SHAPE of the rule, which is unchanged, and that shape is what this type exists to serve. Only the
// ordinary arm moved; he was explicit that the past client look ahead does not.
//
// So this value exists to answer ONE question, asked in ONE place (`StageNavigation.isWithinLeadTime`),
// and no other stage consults a date at all.
//
// A show is a past client's by EITHER route, and Dan chose both having been shown that they catch
// different shows on his own store:
//
//   THE SHOW matched a client, by name or by a booked prior relationship. Stored on the prospect, so it
//   costs nothing to ask.
//
//   THE CALENDAR it came from is a client's, decided by `ClientHorizon`, which is the shipped authority
//   on that question and is asked rather than restated here.
//
// MEASURED on a WAL-consistent clone of the live store, 2026-08-11, because the two routes are not
// interchangeable and the numbers are what settled the design. Of 588 untriaged future shows, 124 sat
// beyond 90 days, every one of them within 11 months. The SHOW route alone catches 23 of those; the
// CALENDAR route catches 36; and all 23 are inside the 36. So on this store the show route adds nothing
// the calendar route has not already found, while the calendar route adds 13 the show route misses.
//
// That inverts the intuition, and the reason is worth keeping: the far-out shows are sitting on Dan's
// CLIENTS' OWN calendars, not on the rooms. DCINY 10, TENET Vocal Artists 10, The Dessoff Choirs 4, The
// Masterwork Chorus 4, Young New Yorkers' Chorus 3, then Opera Praktikos, New York Youth Symphony,
// Morahan Arts, Larchmont Music Academy and Korean Youth Honor Society at 1 each. Carnegie Hall, the
// largest room on the watchlist, contributes 2 far-out shows in total.
//
// Both routes are kept anyway. The show route costs nothing, and the case it covers (a past client
// playing a room Dan watches rather than publishing the date themselves) is ordinary even though it is
// rare in today's far-out set. Dropping a route because today's data does not need it is how a rule
// stops covering the case it was written for.
struct ClientWindow: Equatable, Sendable {
    // No client information at all, so every show is judged on the ordinary window.
    //
    // This is a real answer and not a safe default, which is why it has to be asked for by name: a
    // context built with it says every one of Dan's clients' far-out shows is out of the window. It is
    // correct for a test that is not about clients and wrong for any shipping surface, and
    // `StageContext` takes it as a REQUIRED argument so no call site can arrive at it by forgetting.
    static let none = ClientWindow(clientSourceIds: [])

    // The `sourceId` of every watched source that is a known client's. A precomputed set rather than the
    // roster itself, because deciding it is an O(clients x sources) fuzzy match (#1429 measured that
    // running it per row froze the Sources sheet) and the stage predicate asks it once per show.
    let clientSourceIds: Set<String>

    init(clientSourceIds: Set<String>) {
        self.clientSourceIds = clientSourceIds
    }

    init(sources: [WatchedSource], clients: [DownbeatClient]) {
        self.init(clientSourceIds: ClientHorizon.clientSourceIds(sources: sources, clients: clients))
    }

    func isPastClientShow(_ p: Prospect) -> Bool {
        ClientHorizon.isPastClientShow(p, clientSourceIds: clientSourceIds)
    }
}
