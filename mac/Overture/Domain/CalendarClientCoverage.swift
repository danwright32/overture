import Foundation

// #1424: the real clients in Dan's Shoots calendar that Overture does not treat as returning clients.
//
// Every shoot in that calendar is titled "[Client] Event", and the bracket is the most complete record of
// who has actually hired him: measured on the imported history 2026-09-18, 232 of 322 shoots carry a tag,
// 78 distinct clients, of which 30 match a Downbeat client by name. Overture's picture of "past client"
// comes from Downbeat (and from a watched source Dan tags), so the rest of the calendar's clients are
// invisible to it: their next season is read on the ordinary horizon rather than a year ahead. Dan's call,
// 2026-09-18: flag them, beside the Downbeat coverage check.
//
// A calendar client DOWNBEAT knows is deliberately left out. Whether a watched source covers it is already
// the question `ClientCoverage.unarmed` answers for every Downbeat client, on the same screen, and stating
// it twice would put one fact in two lists (L605).
//
// Pure and tested, never computed in the view (#863).
struct CalendarClient: Equatable, Sendable {
    // The tag as Dan most often writes it, for display. Client names are private: they come from his own
    // calendar and are shown only to him, on his Mac.
    let name: String
    // What a set aside is recorded against: the tag folded the way every name match here folds it, so
    // "[Acme Opera]" and "[ACME OPERA]" are one client.
    let key: String
    let shootCount: Int
    let lastShoot: String          // yyyy-MM-dd
    // A watched source whose name confidently matches but which is not treated as a returning client, so
    // Dan can tag it rather than add a second source. Nil when no source matches.
    let untaggedSourceName: String?
}

extension ShootRecord {
    // The client Dan tags a shoot with, "[Client] Event", or nil when the title carries none. Only a tag at
    // the very START counts: a bracket later in a title ("Spring Gala [rehearsal]") is part of the event's
    // name, not whose shoot it was. An empty or unclosed bracket is no tag.
    //
    // Read from the title in the file, never from the model: since #1904 `VenueShootHistory` keeps no title
    // past its rehearsal rule, and the file keeps them for exactly the readers that need them.
    var clientTag: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }
}

enum CalendarClientCoverage {
    // Set asides share the Downbeat coverage check's own record (`DismissedCoverageClient`), under a key a
    // Downbeat client id can never take (those are UUIDs), so no schema change is needed and one Set aside
    // control means one thing on this screen.
    static let setAsidePrefix = "calendar:"

    static func setAsideKey(_ client: CalendarClient) -> String { setAsidePrefix + client.key }

    static func key(_ tag: String) -> String { GroupNameMatch.tokens(tag).joined(separator: " ") }

    struct Result: Equatable, Sendable {
        // The clients to show, most shot first, then most recently shot.
        let flagged: [CalendarClient]
        // The ones Dan set aside that would otherwise be flagged, so the way back names exactly what it
        // can restore (the #863 promise the Downbeat list already keeps).
        let setAside: [CalendarClient]
        static let empty = Result(flagged: [], setAside: [])
    }

    // Nothing is flagged that Downbeat knows, or that a watched source already treats as a returning
    // client (`ClientHorizon.isClient`, the same rule the horizon itself reads).
    static func result(shoots: [ShootRecord], clients: [DownbeatClient], sources: [WatchedSource],
                       setAsideIds: Set<String>) -> Result {
        let all = uncovered(shoots: shoots, clients: clients, sources: sources)
        return Result(flagged: all.filter { !setAsideIds.contains(setAsideKey($0)) },
                      setAside: all.filter { setAsideIds.contains(setAsideKey($0)) })
    }

    private static func uncovered(shoots: [ShootRecord], clients: [DownbeatClient],
                                  sources: [WatchedSource]) -> [CalendarClient] {
        var byKey: [String: (spellings: [String: Int], count: Int, last: String)] = [:]
        for shoot in shoots {
            guard let tag = shoot.clientTag else { continue }
            let k = key(tag)
            guard !k.isEmpty else { continue }
            var entry = byKey[k] ?? (spellings: [:], count: 0, last: "")
            entry.spellings[tag, default: 0] += 1
            entry.count += 1
            if shoot.date > entry.last { entry.last = shoot.date }
            byKey[k] = entry
        }
        let clientSources = sources.filter { ClientHorizon.isClient($0, clients: clients) }
        return byKey.compactMap { k, entry -> CalendarClient? in
            // The most used spelling, ties broken alphabetically so the name cannot change between draws.
            let name = entry.spellings.max { a, b in
                a.value != b.value ? a.value < b.value : a.key > b.key
            }?.key ?? k
            guard !ClientHorizon.matchesClientName(name, clients: clients) else { return nil }
            guard !clientSources.contains(where: { GroupNameMatch.isConfident($0.orgName, name) }) else {
                return nil
            }
            // A source Dan has tagged "never a returning client" is his answer and is not offered back.
            let untagged = sources.first {
                $0.clientTagOverride == nil && GroupNameMatch.isConfident($0.orgName, name)
            }
            return CalendarClient(name: name, key: k, shootCount: entry.count, lastShoot: entry.last,
                                  untaggedSourceName: untagged?.orgName)
        }
        .sorted {
            if $0.shootCount != $1.shootCount { return $0.shootCount > $1.shootCount }
            if $0.lastShoot != $1.lastShoot { return $0.lastShoot > $1.lastShoot }
            return $0.key < $1.key
        }
    }
}
