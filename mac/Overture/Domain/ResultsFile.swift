import Foundation

// The handoff the scout run writes and the app ingests: fully-formed, ranked
// prospects. Mirrors the wire shape emitted by scripts/export-results.ts. Sibling
// in spirit to Downbeat's downbeat-export.json bridge. `generatedAt` is kept as a
// string (display only) to avoid fractional-second date-parsing fragility.

struct ResultsFile: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var prospects: [ResultProspect]
}

struct ResultProspect: Codable, Equatable, Sendable {
    var groupName: String
    var discipline: String
    var venue: String?
    var performanceDate: String?
    var sourceListingUrl: String?
    var websiteUrl: String?
    var priorRelationship: String
    var production: String
    var profile: String
    var coverage: String
    var fitScore: Int
    var tier: String
    var fitReason: String
    var matchedClientName: String?
    var possibleMatchSource: String?
    var possibleMatchName: String?
}

enum ResultsFileError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum ResultsFileDecoder {
    static let supportedVersion = 1

    static func decode(_ data: Data) throws -> ResultsFile {
        let file = try JSONDecoder().decode(ResultsFile.self, from: data)
        guard file.version == supportedVersion else {
            throw ResultsFileError.unsupportedVersion(file.version)
        }
        return file
    }
}
