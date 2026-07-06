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
    var contacts: [PrepContact]?   // v2 (#392): the act plus at most one presenter, never the venue
    var draft: PrepDraft?

    private enum CodingKeys: String, CodingKey {
        case naturalKey, contacts, contact, draft
    }

    init(naturalKey: String, contacts: [PrepContact]? = nil, draft: PrepDraft? = nil) {
        self.naturalKey = naturalKey
        self.contacts = contacts
        self.draft = draft
    }

    // v1 carried a single `contact` object; v2 carries `contacts[]`. Decode EITHER, mapping a legacy
    // singular contact to a one-element array, so the byte-identical v1 fixture still reads (#132/#140).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        naturalKey = try c.decode(String.self, forKey: .naturalKey)
        draft = try c.decodeIfPresent(PrepDraft.self, forKey: .draft)
        if let many = try c.decodeIfPresent([PrepContact].self, forKey: .contacts) {
            contacts = many
        } else if let one = try c.decodeIfPresent(PrepContact.self, forKey: .contact) {
            contacts = [one]
        } else {
            contacts = nil
        }
    }

    // Always write the v2 shape.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(naturalKey, forKey: .naturalKey)
        try c.encodeIfPresent(contacts, forKey: .contacts)
        try c.encodeIfPresent(draft, forKey: .draft)
    }
}

struct PrepContact: Codable, Equatable, Sendable {
    var name: String?
    var role: String?
    var email: String?
    var method: String?       // named_decision_maker | generic_inbox | form_or_dm
    var confidence: String?   // high | medium | low
    var formUrl: String?
    var provenance: String?   // v2 (#392): act | presenter (never the host venue); v3 (#587) adds performer
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
    // Tolerant version gate (min...supported), mirroring ResultsFileDecoder. An exact-match
    // gate was the brittle pattern that broke the results reader when its version bumped (#132):
    // bumping the contract leaves a closed range that still accepts older files, so a format
    // change can't silently make the reader reject the new (or old) shape (#140).
    static let supportedVersion = 3
    static let minimumVersion = 1

    static func decode(_ data: Data) throws -> PrepResults {
        let results = try JSONDecoder().decode(PrepResults.self, from: data)
        guard (minimumVersion...supportedVersion).contains(results.version) else {
            throw PrepResultsError.unsupportedVersion(results.version)
        }
        return results
    }
}
