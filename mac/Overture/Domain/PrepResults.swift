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
    // #3453: the run's own cost record, decoded for ONE field. `ProbeDurationHistory` decodes this same
    // object for a usable DURATION reading, which is a different question and rightly stays there; what
    // is needed here is only whether the run finished.
    //
    // It is read BESIDE `webCalls.recorded` rather than instead of it, and the reason is historical
    // rather than defensive. Before #3443 (2026-09-01) the two recorders answered "did this stream
    // finish" differently: `record_web_calls` counted a stream that merely PARSED, `record_run_cost`
    // required the terminal result envelope. So on every archive written before that date `webCalls`
    // can claim a run finished when it did not, and `runCost` is the half that was already correct.
    // The real archive `check-run-archives/20260830-205244` is that exact shape: `webCalls.recorded`
    // true, `runCost.recorded` false, `streamsRecorded` 9 of 10, seven shows lost.
    //
    // Since #3443 both recorders share `stream_completed`, so on any file written afterwards the two
    // agree and reading both changes nothing. This is how the truth is recovered from the files written
    // before the fix, which is the only place it can still be hiding.
    var runCost: RunCost? = nil

    struct RunCost: Codable, Equatable, Sendable {
        // Optional, because a file predating the field carries none and absent is not false.
        var recorded: Bool? = nil
    }

    // Whether this run finished, in THREE states rather than two. "Nothing was recorded" is not
    // "it finished": every results file written before #1721 carries no `webCalls` at all, so folding
    // the two together would read the entire history of this store as a series of dead runs (L98, L11).
    enum Completion: Equatable, Sendable { case finished, didNotFinish, notRecorded }

    var completion: Completion {
        if webCalls?.recorded == false || runCost?.recorded == false { return .didNotFinish }
        if webCalls != nil || runCost != nil { return .finished }
        return .notRecorded
    }

    struct WebCalls: Codable, Equatable, Sendable {
        // False when a stream did not report. On that path the writer publishes NO `total` at all, so
        // nothing here can read a partial count as the real one by reaching for the field it always
        // reads. Hence `total` is optional and `recorded` is the thing to branch on.
        var recorded: Bool
        var total: Int? = nil
        // #1835: lookups the permission layer REFUSED, which reached nothing and so are NOT in `total`.
        // Kept as their own figure rather than dropped, because a run repeatedly asking for a tool it does
        // not have is its own signal: dropped, a run blocked at every attempt and one that never needed
        // the web would report exactly the same thing.
        //
        // Absent, not zero, on a results file written before this existed, and on the incomplete path
        // (which carries `partialDenied` instead, the same rule `total` follows). Absent means nobody
        // looked, which is a different claim from "none were refused", so this stays optional and the app
        // says nothing when it is missing.
        var denied: Int? = nil
        // #2387: the same refusals BY ROUTE, which `record_web_calls` has always written
        // (`deniedByRoute` in `lib/models.sh`) and nothing here decoded, so the app threw the one thing
        // away that says whether a refusal is news.
        //
        // The route is the difference between two unrelated pieces of news. A refused BROWSER call is
        // the tool scope holding, working exactly as designed, and there is nothing Dan can grant. A
        // refused fetch or search means the run's ordinary research routes were blocked, which is a real
        // problem. Reported as one number they read identically, which is why he asked on 2026-08-09
        // what he was supposed to do with the line.
        //
        // Optional and additive, and its KEYS are open: an unrecognised route from a newer runner decodes
        // into the dictionary and is reported by name rather than failing the file or being dropped.
        var deniedByRoute: [String: Int]? = nil
        var items: Int = 0
        // #1864: the research TARGETS the allowance was sized for, which is not the number of shows. An
        // organiser-less show pursues every performer its listing names and the runbook puts no headcount
        // ceiling on that, so one show can be five parties. Absent on a results file written before this
        // existed, which reads as "one party per show", exactly what the allowance assumed then.
        var parties: Int? = nil
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
    // v8 (#1824): one plain line saying what this show IS, sourced entirely from the listing text the app
    // rendered and handed over in the queue. The trace that the "read the listing first" rule was actually
    // followed, which otherwise lives only in the prompt (L27), and the line the review card shows Dan so
    // he can see whether the draft beside it was grounded in anything.
    var showSummary: String?
    // v8 (#1824): REQUIRED on any entry with no `showSummary`, and one of ShowSummaryAbsence's three raw
    // values. A raw String, not the enum, for the same reason `emptyReason` is: an unrecognised value from
    // a newer run must decode and then be dropped by the reader, never fail the file and strand Dan's
    // drafts.
    var showSummaryAbsentReason: String?

    private enum CodingKeys: String, CodingKey {
        case naturalKey, contacts, contact, draft, alreadyCoveredNote, emptyReason
        case showSummary, showSummaryAbsentReason
    }

    init(naturalKey: String, contacts: [PrepContact]? = nil, draft: PrepDraft? = nil,
         alreadyCoveredNote: String? = nil, emptyReason: String? = nil,
         showSummary: String? = nil, showSummaryAbsentReason: String? = nil) {
        self.naturalKey = naturalKey
        self.contacts = contacts
        self.draft = draft
        self.alreadyCoveredNote = alreadyCoveredNote
        self.emptyReason = emptyReason
        self.showSummary = showSummary
        self.showSummaryAbsentReason = showSummaryAbsentReason
    }

    // v1 carried a single `contact` object; v2 carries `contacts[]`. Decode EITHER, mapping a legacy
    // singular contact to a one-element array, so the byte-identical v1 fixture still reads (#132/#140).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        naturalKey = try c.decode(String.self, forKey: .naturalKey)
        draft = try c.decodeIfPresent(PrepDraft.self, forKey: .draft)
        alreadyCoveredNote = try c.decodeIfPresent(String.self, forKey: .alreadyCoveredNote)
        emptyReason = try c.decodeIfPresent(String.self, forKey: .emptyReason)
        showSummary = try c.decodeIfPresent(String.self, forKey: .showSummary)
        showSummaryAbsentReason = try c.decodeIfPresent(String.self, forKey: .showSummaryAbsentReason)
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
        try c.encodeIfPresent(showSummary, forKey: .showSummary)
        try c.encodeIfPresent(showSummaryAbsentReason, forKey: .showSummaryAbsentReason)
    }
}

struct PrepContact: Codable, Equatable, Sendable {
    var name: String?
    var role: String?
    // v9 (#2622): who this contact IS to the show, judged by the run from the page it read, never derived
    // here from `role`. See ContactTier for Dan's definition; the run is told it in the runbook, and an
    // unrecognised or absent value decodes as nil, which reads as "nobody has said", not as a tier.
    var tier: String?
    var email: String?
    var method: String?       // named_decision_maker | generic_inbox | form_or_dm
    var confidence: String?   // high | medium | low
    var formUrl: String?
    var provenance: String?   // v2 (#392): act | presenter (never the host venue); v3 (#587) adds performer
    // v11 (#3549) RETIRED `overrideBody`, a second copy of the pitch carried by a performer contact.
    // A show has one letter now, and the address form belongs in it. A payload still carrying the old
    // key decodes fine and the value is ignored, which is the point of decoding by named key: an older
    // Prep run is not an error.
    // v6 (#363): the page this contact was actually read from, so the app's confidence badge can
    // link Dan through to verify it himself. Only ever meaningful when confidence == "high" (the
    // runbook's STRICT verification bar); distinct from formUrl, which stays the form_or_dm
    // contact's own submission link and never doubles as a citation.
    var sourceUrl: String?
    // v10 (#2912): the run's own declaration that the ONLY thing tying this route to the target is the
    // NAME. A social profile carrying the right name and nothing tying it to this show (not the title,
    // not the venue, not the date, not another name on the bill) is now surfaced as a guess rather than
    // withheld: Dan would rather look at a handle for two seconds than never see it, and the search that
    // found it is a search nobody can repeat cheaply.
    //
    // Its OWN field rather than a `confidence` value, which is the whole judgement here. The runbook maps
    // every form or DM to `low` unconditionally, so a CONFIRMED profile is already `low`: the two states
    // Dan has to tell apart would share one value, and the card would be reading a field that cannot
    // answer the question it is being asked. `confidence` goes on saying how good the ROUTE is; this says
    // whether the person on the end of it was established at all.
    //
    // TRUE is the alarming value, deliberately. Absent is what every contact written before this carried
    // and what a run says when it has nothing to declare, so absence reads as "nobody has said", and a run
    // that emits a bare `form_or_dm` is making the verification claim the runbook requires for one. The
    // app never leaves the pair free to disagree: a contact carrying this may not be stored as `high`
    // (ContactConfidenceGuard), so the card reads ONE answer to "how sure are we" (L16).
    var nameMatchOnly: Bool?
    // v11 (#2895): does the page named in `sourceUrl` tie THIS PERSON to THIS PERFORMANCE.
    //
    // Only meaningful for a `performer` contact at `high`, which is the only place the runbook's rule
    // applies: "only use `high` if the source page corroborates that person against THIS SPECIFIC
    // performance". The live case it comes from cited a performer's own portfolio site, which carried
    // their address and never mentioned the show, the venue or the festival, so the address-against-page
    // question was answered and the person-against-performance question was never asked.
    //
    // FALSE is the alarming value, deliberately, exactly like `nameMatchOnly`. Absent is what every
    // contact written before this carried and what a run says when it has nothing to declare, so absence
    // reads as "nobody has said" and changes nothing (Dan's call, 2026-08-21). What that costs is that
    // the rule is dormant until runs emit it, which `PerformerCorroborationAdoption` measures rather than
    // leaving to be discovered (L128).
    var performanceCorroborated: Bool?
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
    // #1824 raised this to 8 with `showSummary`/`showSummaryAbsentReason`, IN THE SAME COMMIT as the
    // fixture, for exactly the reason the paragraph above gives.
    // #2622 raised this to 9 with the contact `tier` field, IN THE SAME COMMIT as `fixtures/prep-results/v9.json`,
    // for exactly the reason the paragraph above gives.
    // #2912 raised this to 10 with the contact `nameMatchOnly` field, IN THE SAME COMMIT as
    // `fixtures/prep-results/v10.json`, for exactly the reason the paragraph above gives.
    static let supportedVersion = 11
    static let minimumVersion = 1

    static func decode(_ data: Data) throws -> PrepResults {
        let results = try JSONDecoder().decode(PrepResults.self, from: data)
        guard (minimumVersion...supportedVersion).contains(results.version) else {
            throw PrepResultsError.unsupportedVersion(results.version)
        }
        return results
    }
}
