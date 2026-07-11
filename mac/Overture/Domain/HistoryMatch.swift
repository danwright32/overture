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
    // #762: the contact address from the booking sheet, when it had one. Exists so a performer-name
    // match found through the HISTORY can be corroborated the same way one found through the Downbeat
    // client list already is. That is the branch most exposed to hitting a different person of the
    // same name, because the history is older and broader than the client list. Optional, so an older
    // file with no addresses still decodes. May hold two addresses in one cell (the booking CSV does).
    var email: String? = nil
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

// The verdict from matching a PERFORMER's name rather than the org's (#749, plan #748, issue #585).
// Note what is NOT here: `suppressed`. This path is positive-match-only by construction, so a
// do-not-contact record reached through a performer's name cannot silently drop a performance;
// do-not-contact suppression stays the org-level matchRelationship's job alone. There is also no
// `possible` bucket: only a confident match auto-corrects, and a fuzzy person-name guess is exactly
// the kind of thing that would put a falsely warm tone in a real email.
struct PerformerMatchVerdict: Equatable, Sendable {
    var relationship: PriorRelationship
    var downbeatClientId: String?
    var matchedClientName: String?
    var matchedPerformerName: String?
    var emailCorroborated: Bool
    var note: String?

    static let noMatch = PerformerMatchVerdict(
        relationship: .none, downbeatClientId: nil, matchedClientName: nil,
        matchedPerformerName: nil, emailCorroborated: false, note: nil
    )

    var isMatch: Bool { relationship != .none }
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

    // Does the performer's own email agree with what Downbeat holds for this client?
    private enum EmailAgreement { case corroborates, conflicts, noSignal }

    // An empty address on either side is no signal at all, NOT a conflict. (DownbeatClient's
    // email/contractEmail are non-optional Strings, so "absent" there is the empty string, not nil.)
    private static func emailAgreement(performerEmail: String, onFile: [String]) -> EmailAgreement {
        let performer = normalizedEmail(performerEmail)
        guard !performer.isEmpty else { return .noSignal }
        let known = onFile.map(normalizedEmail).filter { !$0.isEmpty }
        guard !known.isEmpty else { return .noSignal }
        return known.contains(performer) ? .corroborates : .conflicts
    }

    // Pull the real addresses out of one booking-sheet cell (#762/#779). The cell is free text and,
    // in the real sheet, holds any of: one address, TWO addresses, a contact-form URL, an Instagram
    // handle, or a bare note like "DM on instagram". So this looks for things actually shaped like an
    // address (a local part, an @, then a dotted domain) rather than anything merely containing an @,
    // which would let a URL or a social handle pose as an address that then fails to corroborate.
    private static func addresses(in raw: String?) -> [String] {
        (raw ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]\"'")) }
            .filter { candidate in
                let parts = candidate.split(separator: "@")
                guard parts.count == 2, !parts[0].isEmpty else { return false }
                let domain = parts[1]
                return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
            }
    }

    private static func normalizedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // Match a PERFORMER's name (#749, plan #748, issue #585). Repeat-client detection has always
    // matched the org/group name, so a performance fronted by someone Dan already shot scored cold
    // whenever the group name was new. This is the Prep-time fix.
    //
    // Three guarantees hold BY CONSTRUCTION here rather than by call-site discipline, because each
    // one is a way a caller could otherwise do real damage:
    //
    //  - The production gate lives inside this function, so an agency-produced or unknown-production
    //    performance is never compared at all. A future caller cannot forget to check it.
    //  - Nothing here can suppress a performance: it never touches matchRelationship's do-not-contact
    //    branch, and PerformerMatchVerdict has no `suppressed` field to return. A do-not-contact row
    //    reached through a performer's name is simply dropped, so it neither hides the performance nor
    //    counts as a positive contact signal.
    //  - Only a CONFIDENT (full token-set) name match counts. There is no fuzzy/possible bucket,
    //    because a wrong person-name guess ends up as a falsely warm tone in an email Dan actually sends.
    static func matchPerformer(
        performerName: String,
        performerEmail: String,
        production: Production,
        clients: [DownbeatClient],
        history: [HistoryRecord]
    ) -> PerformerMatchVerdict {
        guard production == .selfProduced else { return .noMatch }
        guard !GroupNameMatch.tokens(performerName).isEmpty else { return .noMatch }

        if let client = clients.first(where: { c in
            clientNames(c).contains { GroupNameMatch.isConfidentPersonName(performerName, $0) }
        }) {
            // Two different people share a name more often than one person changes their email, so a
            // conflicting address is evidence AGAINST the match and nothing is corrected (Dan's call,
            // precision-first). A missing address on either side just leaves the name to decide.
            switch emailAgreement(performerEmail: performerEmail,
                                  onFile: [client.email, client.contractEmail]) {
            case .conflicts:
                return .noMatch
            case .corroborates:
                return PerformerMatchVerdict(
                    relationship: .booked, downbeatClientId: client.id,
                    matchedClientName: client.displayName, matchedPerformerName: performerName,
                    emailCorroborated: true,
                    note: "Matched performer '\(performerName)' to Downbeat client \(client.displayName). Their email matches the address on file."
                )
            case .noSignal:
                return PerformerMatchVerdict(
                    relationship: .booked, downbeatClientId: client.id,
                    matchedClientName: client.displayName, matchedPerformerName: performerName,
                    emailCorroborated: false,
                    note: "Matched performer '\(performerName)' to Downbeat client \(client.displayName)."
                )
            }
        }

        // Booking history carries no email (#762), so name alone decides. Strongest relationship
        // wins, same as matchRelationship: a real relationship (warm) beats a lost outcome on the
        // same person.
        // Per-LINE matching (#755): a history entry is messy free text and may list one performer per
        // line, so the org path's "read the org line" rule would never see the second soloist.
        let confident = history.filter {
            !isStatus($0.status, "dnc")
                && GroupNameMatch.isConfidentPersonName(performerName, inEntry: $0.groupName)
        }
        // The history carries the address from the booking sheet now (#762), so a match found here can
        // be corroborated. But it CORROBORATES ONLY, and a differing address is ignored rather than
        // fatal (#779, Dan's call after the real CSV was imported and inspected).
        //
        // That asymmetry with the client branch is deliberate and data-driven. The sheet's Email
        // column is a "how I contacted them" field, not an identity field: it routinely holds an
        // AGENT's address, an ensemble's, an unrelated org's, or no address at all ("DM on
        // instagram"). So a mismatch there is weak evidence, not evidence against identity, and
        // treating it as fatal would suppress REAL past leads the moment Prep found a performer
        // directly rather than through their agent. A Downbeat client's address IS their own, which
        // is why a conflict there still kills the match.
        let corroborated = confident.contains {
            emailAgreement(performerEmail: performerEmail,
                           onFile: addresses(in: $0.email)) == .corroborates
        }

        let signals = confident.map { relationship(forStatus: $0.status) }
        if let best = signals.max(by: { Ranker.priorPoints($0) < Ranker.priorPoints($1) }),
           isWorthCorrecting(best) {
            return PerformerMatchVerdict(
                relationship: best, downbeatClientId: nil, matchedClientName: nil,
                matchedPerformerName: performerName, emailCorroborated: corroborated,
                note: "Matched performer '\(performerName)' to a past booking-history record."
                    + (corroborated ? " Their email matches the address on file." : "")
            )
        }

        return .noMatch
    }

    // The upgrade-only floor (#763, Dan's call). This is a WARM-lead detector, so a relationship has
    // to actually be worth more than a cold lead to count as a find. Two statuses would otherwise
    // produce a "match" that is worse than useless:
    //
    //  - `contacted` scores 0 (#70: a bare send that got silence is not warm). It would change the
    //    fit score by nothing, yet still set the sticky lock and raise a dismissible flag for Dan,
    //    which is how you train someone to ignore the flag.
    //  - `lostHard` scores -20. Silently downgrading a lead is not this feature's job.
    //
    // Reading the floor off Ranker.priorPoints rather than listing statuses keeps it honest if the
    // weights are ever retuned: whatever the ranker considers better than cold is what counts here.
    private static func isWorthCorrecting(_ r: PriorRelationship) -> Bool {
        Ranker.priorPoints(r) > Ranker.priorPoints(.none)
    }
}
