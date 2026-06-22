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
    static let supportedVersion = 1

    static func decode(_ data: Data) throws -> DownbeatExport {
        let export = try JSONDecoder().decode(DownbeatExport.self, from: data)
        guard export.version == supportedVersion else {
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
}
