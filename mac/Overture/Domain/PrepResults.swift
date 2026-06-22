import Foundation

// The Prep handoff: for each kept prospect, the found contact and the drafted email
// the Prep run produces. The app ingests this and matches by natural key, exactly
// like the scout results file. Sibling format to ResultsFile.

struct PrepResults: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var results: [PrepResult]
}

struct PrepResult: Codable, Equatable, Sendable {
    var naturalKey: String
    var contact: PrepContact?
    var draft: PrepDraft?
}

struct PrepContact: Codable, Equatable, Sendable {
    var name: String?
    var role: String?
    var email: String?
    var method: String?      // named_decision_maker | generic_inbox | form_or_dm
    var confidence: String?  // high | medium | low
    var formUrl: String?
}

struct PrepDraft: Codable, Equatable, Sendable {
    var subject: String
    var body: String
    var variant: String?
}

enum PrepResultsError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum PrepResultsDecoder {
    static let supportedVersion = 1

    static func decode(_ data: Data) throws -> PrepResults {
        let results = try JSONDecoder().decode(PrepResults.self, from: data)
        guard results.version == supportedVersion else {
            throw PrepResultsError.unsupportedVersion(results.version)
        }
        return results
    }
}
