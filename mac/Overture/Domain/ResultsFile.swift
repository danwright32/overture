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
    // Run-collapse fields (#132). Optional in the JSON (absent in pre-132 results files).
    var runEndDate: String?
    var partOfRelatedRun: Bool
    var runSourceUrls: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupName = try c.decode(String.self, forKey: .groupName)
        discipline = try c.decode(String.self, forKey: .discipline)
        venue = try c.decodeIfPresent(String.self, forKey: .venue)
        performanceDate = try c.decodeIfPresent(String.self, forKey: .performanceDate)
        sourceListingUrl = try c.decodeIfPresent(String.self, forKey: .sourceListingUrl)
        websiteUrl = try c.decodeIfPresent(String.self, forKey: .websiteUrl)
        priorRelationship = try c.decode(String.self, forKey: .priorRelationship)
        production = try c.decode(String.self, forKey: .production)
        profile = try c.decode(String.self, forKey: .profile)
        coverage = try c.decode(String.self, forKey: .coverage)
        fitScore = try c.decode(Int.self, forKey: .fitScore)
        tier = try c.decode(String.self, forKey: .tier)
        fitReason = try c.decode(String.self, forKey: .fitReason)
        matchedClientName = try c.decodeIfPresent(String.self, forKey: .matchedClientName)
        possibleMatchSource = try c.decodeIfPresent(String.self, forKey: .possibleMatchSource)
        possibleMatchName = try c.decodeIfPresent(String.self, forKey: .possibleMatchName)
        runEndDate = try c.decodeIfPresent(String.self, forKey: .runEndDate)
        partOfRelatedRun = try c.decodeIfPresent(Bool.self, forKey: .partOfRelatedRun) ?? false
        runSourceUrls = try c.decodeIfPresent([String].self, forKey: .runSourceUrls) ?? []
    }
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
