import Foundation

// The Prep handoff: for each kept prospect, the found contact and the drafted email
// the Prep run produces. The app ingests this and matches by natural key.

struct PrepResults: Codable, Equatable, Sendable {
    var version: Int
    var generatedAt: String
    var results: [PrepResult]
    // #804: which model wrote these drafts. Stamped by the RUNNER SCRIPT after the run (lib/models.sh),
    // never by the model itself: asking a model to write down which model it is invites it to be
    // confidently wrong about the one fact the record exists to establish.
    //
    // Optional, so a results file from before this existed still decodes and still lands Dan's draft. A
    // gap in the record is never a reason to drop his work on the floor.
    var model: String? = nil
    // #1721: how many times the run actually reached the web, counted by the RUNNER from its own event
    // stream (lib/models.sh's record_web_calls), never self-reported by the model. The runbook's hop cap
    // is a sentence in a prompt; this is the measurement.
    //
    // Optional for the same reason `model` is: a results file from before this existed still decodes and
    // still lands Dan's drafts. A gap in the record is never a reason to drop his work on the floor.
    var webCalls: WebCalls? = nil

    struct WebCalls: Codable, Equatable, Sendable {
        // False when a stream did not report. On that path the writer publishes NO `total` at all, so
        // nothing here can read a partial count as the real one by reaching for the field it always
        // reads. Hence `total` is optional and `recorded` is the thing to branch on.
        var recorded: Bool
        var total: Int? = nil
        var items: Int = 0
        var capPerItem: Int = 0
        var allowance: Int = 0
        // Absent when the count is incomplete AND has not already blown the allowance, because that
        // verdict genuinely is not knowable yet.
        var overCap: Bool? = nil
    }
}

struct PrepResult: Codable, Equatable, Sendable {
    var naturalKey: String
    var contacts: [PrepContact]?   // v2 (#392): the act plus at most one presenter, never the venue
    var draft: PrepDraft?
    // v5 (#611): a fit-risk Prep's own research found, e.g. the org's site names its own
    // photographer. Never changes the show's fit score/tier; surfaced to Dan as a dismissible
    // warning so he can deprioritize or skip it himself.
    var alreadyCoveredNote: String?
    // v7 (#1722): WHY this entry carries no contacts. The runbook DISQUALIFIES a venue or press address
    // rather than emitting it at low confidence, so an entry with `contacts` absent is the only trace a
    // refusal leaves, and without this the app cannot tell a check that found the room's own inbox and
    // refused it from one that found nothing at all. Both read "No email found" before this (L11).
    //
    // Optional and additive, so every v6 producer stays valid and no committed fixture changes meaning.
    // A raw String, not the enum: an unrecognised value from a newer run must decode and then be dropped
    // by the reader, never fail the whole file and strand Dan's results.
    var emptyReason: String?

    private enum CodingKeys: String, CodingKey {
        case naturalKey, contacts, contact, draft, alreadyCoveredNote, emptyReason
    }

    init(naturalKey: String, contacts: [PrepContact]? = nil, draft: PrepDraft? = nil,
         alreadyCoveredNote: String? = nil, emptyReason: String? = nil) {
        self.naturalKey = naturalKey
        self.contacts = contacts
        self.draft = draft
        self.alreadyCoveredNote = alreadyCoveredNote
        self.emptyReason = emptyReason
    }

    // v1 carried a single `contact` object; v2 carries `contacts[]`. Decode EITHER, mapping a legacy
    // singular contact to a one-element array, so the byte-identical v1 fixture still reads (#132/#140).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        naturalKey = try c.decode(String.self, forKey: .naturalKey)
        draft = try c.decodeIfPresent(PrepDraft.self, forKey: .draft)
        alreadyCoveredNote = try c.decodeIfPresent(String.self, forKey: .alreadyCoveredNote)
        emptyReason = try c.decodeIfPresent(String.self, forKey: .emptyReason)
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
        try c.encodeIfPresent(emptyReason, forKey: .emptyReason)
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
    // #1722 raised this to 7 with the `emptyReason` field, IN THE SAME COMMIT as the fixture, and it must
    // stay that way. `PrepImporter.answeredKeys` decodes with NO version gate and succeeds on a newer
    // file, while `ingestFile` comes through here and throws, and `consumeIfNew` swallows that with
    // `try?`. If the runner ever writes a version this does not know, markProbed stamps every show in the
    // run with the no-email floor, nothing upgrades it, and the badge locks them out of a re-check for
    // ~90 days with no error anywhere. That is the #1594 shape.
    static let supportedVersion = 7
    static let minimumVersion = 1

    static func decode(_ data: Data) throws -> PrepResults {
        let results = try JSONDecoder().decode(PrepResults.self, from: data)
        guard (minimumVersion...supportedVersion).contains(results.version) else {
            throw PrepResultsError.unsupportedVersion(results.version)
        }
        return results
    }
}
