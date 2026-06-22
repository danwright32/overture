import Foundation

// Repeat-client verdict, ported from historyMatch.ts. Matches a discovered group
// against the canonical Downbeat clients (booked) and the imported booking history
// (contacted / DNC-suppression). Confident matches set the relationship; a fuzzy
// match becomes a "possible" flag for Dan to confirm, never scored.

// Minimal booking-history record the matcher needs (group name + status). The local
// history file the app reads carries these; status is "booked" / "contacted" / "dnc".
struct HistoryRecord: Codable, Equatable, Sendable {
    var groupName: String
    var status: String?
}

struct PossibleMatch: Equatable, Sendable {
    var source: String // "downbeat_client" | "history"
    var ref: String
    var name: String
}

struct MatchVerdict: Equatable, Sendable {
    var relationship: PriorRelationship
    var suppressed: Bool
    var downbeatClientId: String?
    var matchedClientName: String?
    var possible: PossibleMatch?
}

enum HistoryMatch {
    private static func clientNames(_ c: DownbeatClient) -> [String] {
        if let short = c.shortName { return [c.displayName, short] }
        return [c.displayName]
    }

    private static func isStatus(_ status: String?, _ value: String) -> Bool {
        (status ?? "").trimmingCharacters(in: .whitespaces).lowercased() == value
    }

    static func matchRelationship(
        name: String,
        clients: [DownbeatClient],
        history: [HistoryRecord]
    ) -> MatchVerdict {
        let confidentHistory = history.filter { GroupNameMatch.isConfident(name, $0.groupName) }

        // DNC suppression is confident-match-only: a fuzzy name match is never
        // authoritative enough to silently drop a performance (precision over recall).
        if confidentHistory.contains(where: { isStatus($0.status, "dnc") }) {
            return MatchVerdict(relationship: .none, suppressed: true,
                                downbeatClientId: nil, matchedClientName: nil, possible: nil)
        }

        let confidentClient = clients.first { c in
            clientNames(c).contains { GroupNameMatch.isConfident(name, $0) }
        }
        let historyBooked = confidentHistory.contains { isStatus($0.status, "booked") }

        if let client = confidentClient {
            return MatchVerdict(relationship: .booked, suppressed: false,
                                downbeatClientId: client.id, matchedClientName: client.displayName, possible: nil)
        }
        if historyBooked {
            return MatchVerdict(relationship: .booked, suppressed: false,
                                downbeatClientId: nil, matchedClientName: nil, possible: nil)
        }
        if !confidentHistory.isEmpty {
            return MatchVerdict(relationship: .contacted, suppressed: false,
                                downbeatClientId: nil, matchedClientName: nil, possible: nil)
        }

        if let possibleClient = clients.first(where: { c in
            clientNames(c).contains { GroupNameMatch.isPossible(name, $0) }
        }) {
            return MatchVerdict(relationship: .none, suppressed: false,
                                downbeatClientId: nil, matchedClientName: nil,
                                possible: PossibleMatch(source: "downbeat_client", ref: possibleClient.id, name: possibleClient.displayName))
        }

        if let possibleHistory = history.first(where: { GroupNameMatch.isPossible(name, $0.groupName) }) {
            return MatchVerdict(relationship: .none, suppressed: false,
                                downbeatClientId: nil, matchedClientName: nil,
                                possible: PossibleMatch(source: "history", ref: "", name: possibleHistory.groupName))
        }

        return MatchVerdict(relationship: .none, suppressed: false,
                            downbeatClientId: nil, matchedClientName: nil, possible: nil)
    }
}
