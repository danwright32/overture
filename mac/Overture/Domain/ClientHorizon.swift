import Foundation

// #1209: the ONE authority for "is this watched source a known client's, and how far ahead do we read it".
//
// A returning client's new-season shows are the most valuable thing the scout can surface, but they are
// often booked a year out, past the four-month window every other source is read to (#1210). So a client's
// own calendar is read a full YEAR ahead. The decision lives here, in one place, read by BOTH the fetch
// side (how many months of a calendar to stitch) and the Prep side (how far out a show still defaults into
// a run), so the two windows can never drift into two different answers.
//
// "Known client" is: Dan's manual tag if he set one (`clientTagOverride`), otherwise an automatic match of
// the source's org name against the Downbeat client list. The automatic path is DERIVED, never stored, so
// it arms and disarms on its own as clients come and go in Downbeat, with no stale forever-flag.
enum ClientHorizon {
    // A known client's calendar is read current month plus eleven. Twelve so a whole season booked a year
    // ahead is in reach; the ordinary sources keep CalendarMonthIndex.defaultHorizon (four).
    static let clientMonths = 12

    // The org name confidently matches a Downbeat client, by the SAME names and matcher HistoryMatch uses
    // to recognize a client's SHOW, so a source and a show can never disagree about who is a client.
    static func matchesClientName(_ orgName: String, clients: [DownbeatClient]) -> Bool {
        clients.contains { c in
            HistoryMatch.clientNames(c).contains { GroupNameMatch.isConfident(orgName, $0) }
        }
    }

    // Is this source a known client's own calendar? Dan's tag wins in both directions; absent a tag, the
    // org-name match decides.
    static func isClient(_ source: WatchedSource, clients: [DownbeatClient]) -> Bool {
        if let override = source.clientTagOverride { return override }
        return matchesClientName(source.orgName, clients: clients)
    }

    // The `isClient` verdict for every source at once, keyed by sourceId (#1429). The Sources sheet used to
    // call `isClient` inline once PER row on every redraw, and each call runs a token-set fuzzy match over
    // the whole client list, so a long scroll (with the sheet re-running its list on every tick) piled that
    // work onto the main thread. Computing the map once lets the sheet cache it and read each row's flag in
    // O(1). It returns exactly what `isClient` returns for each source (a test pins the two equal), so the
    // sheet's cached read can never disagree with the authority.
    static func clientFlags(sources: [WatchedSource], clients: [DownbeatClient]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for source in sources {
            out[source.sourceId] = isClient(source, clients: clients)
        }
        return out
    }

    // The month horizon this source's calendar is read to.
    static func months(for source: WatchedSource, clients: [DownbeatClient]) -> Int {
        isClient(source, clients: clients) ? clientMonths : CalendarMonthIndex.defaultHorizon
    }

    // The Prep-run default window for a prospect: the client year if it came from a client's source (auto
    // or tagged) OR it itself matched a client (a booked relationship), else the ordinary four months. The
    // second arm catches a client's show that surfaced from a NON-client source (a shared venue's own
    // calendar that Dan has not tagged): the show still resolved to the client by name, so it is still one
    // worth defaulting in a year out.
    static func prepMonths(for prospect: Prospect, sources: [WatchedSource], clients: [DownbeatClient]) -> Int {
        let fromClientSource = sources.contains { s in
            prospect.sourceIds.contains(s.sourceId) && isClient(s, clients: clients)
        }
        let matchedAClient = prospect.priorRelationship == "booked" || prospect.matchedClientName != nil
        return (fromClientSource || matchedAClient) ? clientMonths : CalendarMonthIndex.defaultHorizon
    }
}
