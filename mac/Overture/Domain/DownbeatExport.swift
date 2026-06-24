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

struct DownbeatExport: Codable, Equatable, Sendable {
    var version: Int
    var clients: [DownbeatClient]
    var venues: [DownbeatVenue]
}

enum DownbeatExportError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum DownbeatBridge {
    // v1 = clients/venues; v2 adds bookings/blockedDates (downbeat#52). Swift Codable
    // ignores keys this struct doesn't declare, so accepting v2 reads clients/venues
    // without consuming the new keys yet (that's #99). Keep v1 working.
    static let supportedVersions: Set<Int> = [1, 2]

    static func decode(_ data: Data) throws -> DownbeatExport {
        let export = try JSONDecoder().decode(DownbeatExport.self, from: data)
        guard supportedVersions.contains(export.version) else {
            throw DownbeatExportError.unsupportedVersion(export.version)
        }
        return export
    }

    static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
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
            return "The Downbeat client export couldn't be read (it may be corrupted or a newer format), so the scout treated every prospect as cold. Re-export it from Downbeat."
        case .stale(let days):
            return "Your Downbeat client export is \(days) days old. Recently booked clients may be missing, so some warm leads could look cold. Open Downbeat to refresh it."
        }
    }

    // Reads whatever clients it can, plus a health verdict. Never throws: a missing or
    // bad export yields empty clients so the scout still runs, with the warning surfaced.
    static func loadWithHealth(from url: URL = defaultURL, now: Date,
                               staleAfter: TimeInterval = defaultStaleAfter)
        -> (clients: [DownbeatClient], health: Health) {
        guard let data = try? Data(contentsOf: url) else {
            return ([], .missing)
        }
        let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let export = try? decode(data) else {
            return ([], health(fileExists: true, decodeFailed: true, modifiedAt: modifiedAt ?? nil, now: now, staleAfter: staleAfter))
        }
        return (export.clients, health(fileExists: true, decodeFailed: false, modifiedAt: modifiedAt ?? nil, now: now, staleAfter: staleAfter))
    }
}
