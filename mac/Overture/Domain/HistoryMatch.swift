import Foundation

// Repeat-client verdict. Matches a discovered group against the canonical Downbeat clients
// (booked) and the imported booking history (contacted / DNC-suppression). Confident matches
// set the relationship; a fuzzy match becomes a "possible" flag for Dan to confirm, never
// scored. Used to be kept identical to a TypeScript mirror (historyMatch.ts), retired in #493.

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

    // The history status vocabulary the ranker understands. An unrecognized or empty status
    // on a confidently matched record is treated as a neutral cold contact, never a boost.
    private static func relationship(forStatus status: String?) -> PriorRelationship {
        switch (status ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "booked": return .booked
        case "declined": return .declinedByYou
        case "warm": return .warm
        case "lost_soft": return .lostSoft
        case "lost_hard": return .lostHard
        default: return .contacted
        }
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
        if let client = confidentClient {
            return MatchVerdict(relationship: .booked, suppressed: false,
                                downbeatClientId: client.id, matchedClientName: client.displayName, possible: nil)
        }
        // Resolve the history signals to the strongest relationship by fit weight, so a real
        // relationship (warm) beats a lost outcome on the same org, and a booked history beats
        // everything below it. A bare cold send is `contacted` (neutral, 0), not warm (#70).
        let signals = confidentHistory.map { relationship(forStatus: $0.status) }
        if let best = signals.max(by: { Ranker.priorPoints($0) < Ranker.priorPoints($1) }) {
            return MatchVerdict(relationship: best, suppressed: false,
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
