import Foundation

// The Prep handoff: for each kept prospect, the found contact and the drafted email
// the Prep run produces. The app ingests this and matches by natural key.

struct PrepResults: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var results: [PrepResult]
}

struct PrepResult: Codable, Equatable, Sendable {
    var naturalKey: String
    var contacts: [PrepContact]?   // v2 (#392): the act plus at most one presenter, never the venue
    var draft: PrepDraft?
    // v5 (#611): a fit-risk Prep's own research found, e.g. the org's site names its own
    // photographer. Never changes the show's fit score/tier; surfaced to Dan as a dismissible
    // warning so he can deprioritize or skip it himself.
    var alreadyCoveredNote: String?

    private enum CodingKeys: String, CodingKey {
        case naturalKey, contacts, contact, draft, alreadyCoveredNote
    }

    init(naturalKey: String, contacts: [PrepContact]? = nil, draft: PrepDraft? = nil,
         alreadyCoveredNote: String? = nil) {
        self.naturalKey = naturalKey
        self.contacts = contacts
        self.draft = draft
        self.alreadyCoveredNote = alreadyCoveredNote
    }

    // v1 carried a single `contact` object; v2 carries `contacts[]`. Decode EITHER, mapping a legacy
    // singular contact to a one-element array, so the byte-identical v1 fixture still reads (#132/#140).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        naturalKey = try c.decode(String.self, forKey: .naturalKey)
        draft = try c.decodeIfPresent(PrepDraft.self, forKey: .draft)
        alreadyCoveredNote = try c.decodeIfPresent(String.self, forKey: .alreadyCoveredNote)
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
        try c.encodeIfPresent(alreadyCoveredNote, forKey: .alreadyCoveredNote)
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
    // v4 (#639, #634 Phase A): only meaningful when provenance == "performer", a direct, second-person
    // draft body for THIS contact, used instead of the shared (third-person) PrepResult.draft.body when
    // emailing a named performer directly rather than a third party describing them.
    var overrideBody: String?
    // v6 (#363): the page this contact was actually read from, so the app's confidence badge can
    // link Dan through to verify it himself. Only ever meaningful when confidence == "high" (the
    // runbook's STRICT verification bar); distinct from formUrl, which stays the form_or_dm
    // contact's own submission link and never doubles as a citation.
    var sourceUrl: String?
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
    // Tolerant version gate (min...supported). An exact-match gate was the brittle pattern
    // that broke the results reader when its version bumped (#132):
    // bumping the contract leaves a closed range that still accepts older files, so a format
    // change can't silently make the reader reject the new (or old) shape (#140).
    static let supportedVersion = 6
    static let minimumVersion = 1

    static func decode(_ data: Data) throws -> PrepResults {
        let results = try JSONDecoder().decode(PrepResults.self, from: data)
        guard (minimumVersion...supportedVersion).contains(results.version) else {
            throw PrepResultsError.unsupportedVersion(results.version)
        }
        return results
    }
}
