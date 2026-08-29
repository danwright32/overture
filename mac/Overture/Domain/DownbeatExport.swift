import Foundation

// Reads Downbeat's local client/venue export (the bridge file Downbeat writes at
// ~/Library/Application Support/Overture/downbeat-export.json). Mirrors the wire
// format in downbeatBridge.ts / OvertureExportModels.swift; version-gated.

struct DownbeatClient: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var shortName: String?
    var email: String
    var contractEmail: String
    var phoneNumber: String?
    var isTaxExempt: Bool?
    var hasLeftReview: Bool
    var specialBehaviors: [String]
    var notes: String?
    var hostingSite: String

    // Clients ordered for display, case-insensitively by name (#1429). The Sources sheet's "Always" submenu
    // shows the whole roster this way; sorting is done once through this helper at load rather than rebuilt
    // every time a row's menu is drawn.
    static func sortedByName(_ clients: [DownbeatClient]) -> [DownbeatClient] {
        clients.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

struct DownbeatVenue: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var address: String?
    var editingProfile: String?
    var specialBehaviors: [String]
    var staffNotificationEmails: [String]
    var notes: String?
}

struct OvertureBooking: Codable, Equatable, Sendable {
    var id: String
    var clientId: String
    var clientDisplayName: String
    var shootName: String
    var startDate: String
    var endDate: String
    var venueId: String?      // OMITTED for ad-hoc venues; match on venueName then
    var venueName: String
}

struct DownbeatExport: Codable, Equatable, Sendable {
    var version: Int
    var clients: [DownbeatClient]
    var venues: [DownbeatVenue]
    var bookings: [OvertureBooking]
    // Calendar days (yyyy-MM-dd) Dan is already shooting, added in export v2. The scout
    // suppresses performances on these; absent in a v1 file (#156). May include past days.
    var blockedDates: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        clients = try c.decode([DownbeatClient].self, forKey: .clients)
        venues = try c.decode([DownbeatVenue].self, forKey: .venues)
        bookings = try c.decodeIfPresent([OvertureBooking].self, forKey: .bookings) ?? []
        blockedDates = try c.decodeIfPresent([String].self, forKey: .blockedDates) ?? []
    }
}

enum DownbeatExportError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum DownbeatBridge {
    // v1 = clients/venues; v2 adds bookings/blockedDates (downbeat#52). Swift Codable
    // ignores keys this struct doesn't declare, so accepting v2 reads clients/venues
    // without consuming the new keys yet (that's #99). Keep v1 working.
    //
    // #3193: this was the exact set [1, 2] and is now a MINIMUM with no ceiling, which is the
    // opposite direction from `PrepResultsDecoder`'s closed `minimumVersion...supportedVersion`
    // range, deliberately. That reader's ceiling exists because Overture WRITES the queue the run
    // answers, so a results file naming a version it does not know means the run wrote a shape this
    // build cannot act on, and reading it half-way stamps every show in the run with a floor nothing
    // upgrades (#1594). This file is the reverse: Overture only ever READS it, from a producer in
    // another repo on its own release schedule, the format is additive by contract, and the failure
    // mode of refusing is total. A throw here is answered by `loadWithHealth` with empty clients,
    // empty bookings and empty blockedDates, so the roster empties AND the scout stops suppressing
    // nights Dan is already shooting, which is a pitch for a night that is taken. Downbeat bumping
    // its format is the ordinary case, not an error, so a version at or above the minimum is read
    // for the keys this struct declares and the rest are ignored (L255).
    static let minimumVersion = 1

    static func decode(_ data: Data) throws -> DownbeatExport {
        let export = try JSONDecoder().decode(DownbeatExport.self, from: data)
        guard export.version >= minimumVersion else {
            throw DownbeatExportError.unsupportedVersion(export.version)
        }
        return export
    }

    static var defaultURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("downbeat-export.json")
    }

    static func load(from url: URL = defaultURL) throws -> DownbeatExport {
        try decode(try Data(contentsOf: url))
    }

    // How healthy the past-client export is, so the scout can warn instead of silently
    // treating every prospect as a cold lead (#22/#23).
    static let defaultStaleAfter: TimeInterval = 30 * 86_400  // 30 days

    enum Health: Equatable, Sendable {
        case ok
        case missing            // no export file at all
        case unreadable         // present but couldn't decode / wrong shape / bad version
        case stale(ageDays: Int)
    }

    // Pure verdict from the facts the IO wrapper gathers.
    static func health(fileExists: Bool, decodeFailed: Bool, modifiedAt: Date?,
                       now: Date, staleAfter: TimeInterval) -> Health {
        if !fileExists { return .missing }
        if decodeFailed { return .unreadable }
        if let modifiedAt, now.timeIntervalSince(modifiedAt) > staleAfter {
            return .stale(ageDays: Int(now.timeIntervalSince(modifiedAt) / 86_400))
        }
        return .ok
    }

    static func warningText(for health: Health) -> String? {
        switch health {
        case .ok:
            return nil
        case .missing:
            return "No Downbeat client export was found, so the scout treated every prospect as a cold lead. Open Downbeat to export your client list, then run the scout again."
        case .unreadable:
            return "The Downbeat client export couldn't be read (it may be corrupted, or not the shape Overture expects), so the scout treated every prospect as cold. Re-export it from Downbeat."
        case .stale(let days):
            return "Your Downbeat client export is \(days) days old. Recently booked clients may be missing, so some warm leads could look cold. Open Downbeat to refresh it."
        }
    }

    // #901: just the two halves the blocked calendar is built from. A convenience over loadWithHealth, so
    // the three places that need the export in order to judge a date (the scout, the Days off sheet, and
    // the sweep that runs when Dan edits his days off) do not each re-destructure the same tuple.
    static func loadedExport() -> (bookings: [OvertureBooking], blockedDates: [String]) {
        let loaded = loadWithHealth(now: Date())
        return (loaded.bookings, loaded.blockedDates)
    }

    // Reads whatever clients it can, plus a health verdict. Never throws: a missing or
    // bad export yields empty clients so the scout still runs, with the warning surfaced.
    static func loadWithHealth(from url: URL = defaultURL, now: Date,
                               staleAfter: TimeInterval = defaultStaleAfter)
        -> (clients: [DownbeatClient], bookings: [OvertureBooking], blockedDates: [String], health: Health) {
        // #2879: through the shared reader, exempt from the register because a broken export already
        // has the loudest line on the masthead (AppNotices.downbeatShootsVanished and the health verdict
        // below), and a second generic wording of it would be the same fault said twice (#843).
        // A file present and unopenable now reads as a DECODE FAILURE rather than as missing: it used to
        // take this branch and report `.missing`, which says the export was never made.
        let read = HandoffFile.data(at: url, recorder: .reportedByItsOwnSurface)
        if case .absent = read { return ([], [], [], .missing) }
        guard let data = read.value else {
            return ([], [], [], health(fileExists: true, decodeFailed: true,
                                       modifiedAt: FileTimestamp.modifiedAt(url) ?? nil,
                                       now: now, staleAfter: staleAfter))
        }
        // #2105: the shared read, and the one site here that was genuinely exposed rather than safe by
        // luck: `url` is a PARAMETER, so a caller holding one in a `let` and reading it twice would have
        // been told the first answer both times, including after the export was replaced.
        let modifiedAt = FileTimestamp.modifiedAt(url)
        guard let export = try? decode(data) else {
            return ([], [], [], health(fileExists: true, decodeFailed: true, modifiedAt: modifiedAt ?? nil, now: now, staleAfter: staleAfter))
        }
        return (export.clients, export.bookings, export.blockedDates,
                health(fileExists: true, decodeFailed: false, modifiedAt: modifiedAt ?? nil, now: now, staleAfter: staleAfter))
    }
}
