import Foundation

// #1895 (part of #1887): every past shoot Dan has photographed, with its venue and date, so a
// pitch can say he has shot this room before.
//
// Written by `scripts/import-shoot-history.ts` from an iCalendar export of Dan's "Shoots" Google
// Calendar, which holds the real history back to 2018. Deliberately a one-shot manual import
// rather than a live calendar read: Overture holds no standing calendar permission and asks for
// none (Dan's call). The cost of that is staleness, which is why `Health` exists here.
//
// The `venue` strings arrive EXACTLY as the calendar writes them, unfolded but not normalised:
// 42 of 322 carry an embedded newline instead of a comma, 40 are wrapped in double quotes. The
// importer does no folding on purpose, so this cannot become a fourth name vocabulary drifting
// from the three the app already has. Folding them is `VenueShootHistory`'s job (#1896).

struct ShootRecord: Codable, Equatable, Sendable {
    var venue: String
    var date: String    // YYYY-MM-DD, already converted to Eastern by the importer
    var title: String
}

struct ShootHistoryFile: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var shoots: [ShootRecord]
}

enum ShootHistory {
    static let currentVersion = 1

    // 120 days. Longer than the Downbeat export's 30, because this file is refreshed by hand
    // rather than written automatically on every save, so a monthly nag would be noise. Short
    // enough that a season's worth of new rooms cannot go unmentioned in a pitch.
    static let defaultStaleAfter: TimeInterval = 120 * 86_400

    enum Health: Equatable, Sendable {
        case ok
        case missing        // no import has been run; a normal state, not a fault
        case unreadable     // present but corrupt, wrong shape, or a version this build predates
        case stale(ageDays: Int)
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("overture-shoot-history.json")
    }

    // Pure verdict from the facts the IO wrapper gathers. `generatedAt` is the file's own stamp
    // rather than its modification time on purpose: copying, restoring from a backup, or syncing
    // the file must not make an old export look fresh.
    static func health(fileExists: Bool, decodeFailed: Bool, generatedAt: Date?,
                       now: Date, staleAfter: TimeInterval) -> Health {
        if !fileExists { return .missing }
        if decodeFailed { return .unreadable }
        // A timestamp that will not parse is a broken file, not a fresh one. Reading it as
        // healthy would put the reassuring answer on the unreadable case (L50).
        guard let generatedAt else { return .unreadable }
        let age = now.timeIntervalSince(generatedAt)
        if age > staleAfter { return .stale(ageDays: Int(age / 86_400)) }
        return .ok
    }

    static func warningText(for health: Health) -> String? {
        switch health {
        case .ok:
            return nil
        case .missing:
            return "No shoot history has been imported, so pitches can't mention rooms you've photographed before. Export your Shoots calendar and run the shoot-history import."
        case .unreadable:
            return "The shoot history file couldn't be read (it may be corrupted or a newer format), so pitches can't mention rooms you've photographed before. Re-run the shoot-history import."
        case .stale(let days):
            return "Your shoot history is \(days) days old, so rooms you've photographed since then won't be mentioned in a pitch. Re-export your Shoots calendar and run the import again."
        }
    }

    // Reads whatever it can, plus a health verdict. Never throws: a missing or bad file yields no
    // shoots so drafting still runs, with the warning surfaced rather than swallowed.
    //
    // A STALE file keeps its shoots. An old count is still a floor on how many times Dan has shot
    // the room, and throwing real history away because it might be incomplete would make the
    // pitch say less than the app knows.
    static func loadWithHealth(from url: URL = defaultURL, now: Date,
                               staleAfter: TimeInterval = defaultStaleAfter)
        -> (shoots: [ShootRecord], health: Health) {
        // #2879: through the shared reader, which already separates absent from unreadable, exactly
        // the distinction Health draws. It uses the exemption that does not report, because this file's
        // read failure has its OWN masthead line (AppNotices.shootHistoryWarning), which says more than
        // a generic one could and would otherwise be joined by a second wording of the same fault.
        let file: ShootHistoryFile
        let read = HandoffFile.read(at: url, recorder: .reportedByItsOwnSurface) {
            try JSONDecoder().decode(ShootHistoryFile.self, from: $0)
        }
        switch read {
        case .absent:
            return ([], health(fileExists: false, decodeFailed: false, generatedAt: nil,
                               now: now, staleAfter: staleAfter))
        case .unreadable:
            return ([], health(fileExists: true, decodeFailed: true, generatedAt: nil,
                               now: now, staleAfter: staleAfter))
        case .read(let decoded) where decoded.version != currentVersion:
            return ([], health(fileExists: true, decodeFailed: true, generatedAt: nil,
                               now: now, staleAfter: staleAfter))
        case .read(let decoded):
            file = decoded
        }
        let stamp = parseTimestamp(file.generatedAt)
        let verdict = health(fileExists: true, decodeFailed: false, generatedAt: stamp,
                             now: now, staleAfter: staleAfter)
        // An unparseable stamp is a broken file, so it reports nothing rather than reporting
        // shoots it cannot date the freshness of.
        if verdict == .unreadable { return ([], verdict) }
        return (file.shoots, verdict)
    }

    // The importer writes fractional seconds (JavaScript's toISOString), which the plain
    // ISO8601DateFormatter rejects, so both spellings are tried.
    //
    // Built per call rather than held in a static: ISO8601DateFormatter is not Sendable, so a
    // shared instance is a Swift 6 concurrency error. This runs once per file load, so there is
    // nothing to gain by caching it.
    static func parseTimestamp(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
