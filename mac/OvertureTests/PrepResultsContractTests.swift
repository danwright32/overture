import Testing
import Foundation

// The Swift reader half of the Prep results contract (#157). The WRITER is the Prep Claude Code
// workflow (docs/prep-runbook.md), not code, so there is no second programmatic side to assert —
// this fixture pins the Swift decode and is the canonical example the runbook points the workflow
// at. A change to PrepResults' shape breaks this test, forcing the runbook + fixture to update in
// lockstep instead of the workflow silently writing a file the app can't ingest (the #109 class).
@Suite("Prep results contract fixtures")
struct PrepResultsContractTests {
    private func fixtureDirectory() -> URL {
        RepoRoot.url
            .appendingPathComponent("fixtures/prep-results")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491/#744: enumerates whatever is actually committed, so a new fixture file with no
    // matching decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try PrepResultsDecoder.decode(data)
            }
        }
    }

    // The legacy v1 shape carried a single `contact` object. v2 (#392) replaces it with `contacts[]`,
    // and the custom init(from:) maps a v1 singular `contact` to a one-element `contacts` array so
    // the byte-identical v1 fixture still decodes — the #132/#140 anti-brittleness pattern. These
    // assertions read through `contacts?.first` to prove the shim.
    @Test func decodesTheV1FixtureToTheAgreedLogicalShape() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v1.json"))
        #expect(results.version == 1)
        #expect(results.results.count == 4)

        // Full result: named decision-maker contact + a drafted email with a recorded variant.
        let full = results.results[0]
        #expect(full.naturalKey == "aurora-strings|2026-03-10|carnegie-hall")
        #expect(full.contacts?.count == 1)
        #expect(full.contacts?.first?.name == "Emma Robinson")
        #expect(full.contacts?.first?.method == "named_decision_maker")
        #expect(full.contacts?.first?.confidence == "high")
        #expect(full.draft?.subject == "Photographing Aurora Strings at Carnegie Hall.")
        #expect(full.draft?.variant == "rate_stated")

        // Contact found but no draft yet: contact present with its own optionals nil, draft absent.
        let contactOnly = results.results[1]
        #expect(contactOnly.contacts?.count == 1)
        #expect(contactOnly.contacts?.first?.name == nil)
        #expect(contactOnly.contacts?.first?.method == "generic_inbox")
        #expect(contactOnly.contacts?.first?.email == "info@lumendance.example")
        #expect(contactOnly.draft == nil)

        // Bare result (key echoed, nothing found): both contacts and draft absent.
        let bare = results.results[2]
        #expect(bare.naturalKey == "unmatched|key|here")
        #expect(bare.contacts == nil)
        #expect(bare.draft == nil)
    }

    // The act has no published email, only a contact form (#368, the Ivalas Quartet case). The
    // contract must carry a form-only contact: a contactForm method with a formUrl and NO email,
    // so the app can surface the form as the way to reach the act instead of falling back to a
    // venue inbox. Pins that this shape round-trips through PrepResults (v1 legacy shim).
    @Test func decodesAFormOnlyActContact() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v1.json"))
        let formOnly = results.results[3]
        #expect(formOnly.naturalKey == "ivalas-quartet|2026-07-01|madison-square-park")
        #expect(formOnly.contacts?.first?.method == "form_or_dm")
        #expect(formOnly.contacts?.first?.confidence == "low")
        #expect(formOnly.contacts?.first?.email == nil)
        #expect(formOnly.contacts?.first?.formUrl == "https://www.ivalasquartet.com/contact")
    }

    // v2 (#392): multiple contacts per performance, each with a provenance label (act / presenter,
    // never the host venue). The tolerant gate (1...2) still accepts the v1 file above.
    @Test func decodesTheV2FixtureWithMultipleContactsAndProvenance() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v2.json"))
        #expect(results.version == 2)

        // The act plus one presenting org, both with provenance labels.
        let multi = results.results[0]
        #expect(multi.contacts?.count == 2)
        #expect(multi.contacts?[0].provenance == "act")
        #expect(multi.contacts?[0].name == "Emma Robinson")
        #expect(multi.contacts?[1].provenance == "presenter")
        #expect(multi.contacts?[1].email == "tickets@presentingorg.example")

        // A form-only act still carries through with its provenance and no email.
        let formOnly = results.results[1]
        #expect(formOnly.contacts?.count == 1)
        #expect(formOnly.contacts?.first?.provenance == "act")
        #expect(formOnly.contacts?.first?.email == nil)
        #expect(formOnly.contacts?.first?.formUrl == "https://www.ivalasquartet.com/contact")
    }

    // v3 (#587, #366 Phase 2): a named individual performer on a self-produced show carries a
    // `performer` provenance, distinct from `act` (a single-act waterfall result). The tolerant gate
    // (1...3) still accepts the v1/v2 fixtures above.
    @Test func decodesTheV3FixtureWithPerformerProvenance() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v3.json"))
        #expect(results.version == 3)

        let performerOnly = results.results[0]
        #expect(performerOnly.contacts?.count == 1)
        #expect(performerOnly.contacts?.first?.provenance == "performer")
        #expect(performerOnly.contacts?.first?.name == "Maya Chen")
        #expect(performerOnly.contacts?.first?.email == "maya@midnightquartet.example")
    }

    // v5 (#611): an optional alreadyCoveredNote flags a fit-risk Prep's own research found (the
    // org's site names its own photographer), surfaced to Dan so he can deprioritize or skip
    // without the show's fit score/tier changing. The tolerant gate (1...5) still accepts the
    // v1/v2/v3/v4 fixtures above.
    @Test func decodesTheV5FixtureWithAnAlreadyCoveredNote() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v5.json"))
        #expect(results.version == 5)

        let flagged = results.results[0]
        #expect(flagged.naturalKey == "french-american-piano-society|2026-09-12|weill-recital-hall")
        #expect(flagged.alreadyCoveredNote == "The organization's site lists a Photographer in Residence on its About page.")
        #expect(flagged.contacts?.first?.provenance == "presenter")
        #expect(flagged.draft?.subject == "Photographing the French-American Piano Society's recital at Weill Recital Hall.")
    }

    // v6 (#363): an optional sourceUrl on a contacts[] entry, the page the run actually read a
    // high-confidence contact from, so the app's confidence badge can link Dan through to verify
    // it himself. Distinct from formUrl, which stays the form_or_dm contact's own submission
    // link. Only ever meaningful at confidence == "high"; the tolerant gate (1...6) still accepts
    // the v1/v2/v3/v4/v5 fixtures above.
    @Test func decodesTheV6FixtureWithASourceURL() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v6.json"))
        #expect(results.version == 6)

        let multi = results.results[0]
        #expect(multi.naturalKey == "aurora-strings|2026-03-10|carnegie-hall")
        #expect(multi.contacts?.count == 2)
        #expect(multi.contacts?[0].confidence == "high")
        #expect(multi.contacts?[0].sourceUrl == "https://www.aurorastrings.example/about/staff")
        // A medium-confidence contact carries no source citation.
        #expect(multi.contacts?[1].confidence == "medium")
        #expect(multi.contacts?[1].sourceUrl == nil)
        // #5 Phase 0: `variant` now carries the opener archetype the drafter actually produced (one of
        // the four #362 shapes), not the retired constant "rate_stated". This fixture's body is a
        // reason-first opener ("I photograph performing arts in New York and saw ..."), so its echo is
        // that token. (The frozen v1-v5 fixtures keep their historical "rate_stated" and are untouched.)
        #expect(multi.draft?.variant == "reason-first")
    }

    // #2622: v9 adds `tier` to a contact. The version gate rose with it, in the same commit as the
    // fixture, which is the rule the decoder's own comment states and the reason #1594's shape cannot
    // repeat.
    @Test func decodesTheV9FixtureWithAContactTier() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v9.json"))
        #expect(results.version == 9)

        let contact = try #require(results.results.first?.contacts?.first)
        #expect(contact.tier == "primary")
        #expect(ContactTier(rawValue: try #require(contact.tier)) == .primary)
    }

    // Additive: every earlier fixture still decodes, and reads as nobody having said, never as a tier.
    @Test func anearlierFixtureCarriesNoTier() throws {
        let v8 = try PrepResultsDecoder.decode(try fixture("v8.json"))
        #expect(v8.results.first?.contacts?.first?.tier == nil)
    }

    // #2912: v10 adds `nameMatchOnly` to a contact. The version gate rose with it, in the same commit as
    // the fixture, which is the rule the decoder's own comment states and the reason #1594's shape cannot
    // repeat. The fixture carries BOTH shapes on one show deliberately: the handle nobody could tie to
    // the show, and the address read off a page, because that pair is what the card has to tell apart.
    @Test func decodesTheV10FixtureWithANameMatchOnlyContact() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v10.json"))
        #expect(results.version == 10)

        let contacts = try #require(results.results.first?.contacts)
        #expect(contacts.first?.nameMatchOnly == true)
        #expect(contacts.first?.confidence == "low")
        #expect(contacts.last?.nameMatchOnly == nil)
        #expect(contacts.last?.confidence == "high")
    }

    // Additive: an earlier fixture reads as nobody having said it is a guess, which is not the same
    // claim as somebody having confirmed it, and nothing on the card asserts one from the other.
    @Test func anearlierFixtureCarriesNoNameMatchFlag() throws {
        let v9 = try PrepResultsDecoder.decode(try fixture("v9.json"))
        #expect(v9.results.first?.contacts?.first?.nameMatchOnly == nil)
    }

    // #2895: v11 adds `performanceCorroborated` to a contact. The version gate rose with it, in the same
    // commit as the fixture, which is the rule the decoder's own comment states.
    //
    // The fixture is built from the REAL 2026-08-17 case and takes invented people (L48, L155): a named
    // performer emitted at `high` off a page that establishes nobody, beside one whose cited page does tie
    // them to this booking. That pair is what the guard has to tell apart, and it is the same reason the
    // v10 fixture carries both of its shapes on one show.
    @Test func decodesTheV11FixtureWithAcorroborationDeclaration() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v11.json"))
        #expect(results.version == 11)

        let contacts = try #require(results.results.first?.contacts)
        #expect(contacts.first?.performanceCorroborated == false)
        #expect(contacts.first?.provenance == "performer")
        #expect(contacts.first?.confidence == "high", "what the RUN claimed; the guard is what lowers it")
        #expect(contacts.last?.performanceCorroborated == true)
    }

    // Additive: an earlier fixture reads as nobody having said whether the page corroborates, which is not
    // the same claim as somebody having said it does, and nothing asserts one from the other.
    @Test func anearlierFixtureCarriesNoCorroborationDeclaration() throws {
        let v10 = try PrepResultsDecoder.decode(try fixture("v10.json"))
        for contact in v10.results.first?.contacts ?? [] {
            #expect(contact.performanceCorroborated == nil)
        }
    }

    // MARK: - Negative paths (#747)
    //
    // The enumeration guard above only proves a POSITIVE: every committed fixture decodes. That
    // says nothing about whether the decoder would REJECT a bad file, and a guard that cannot fail
    // is not a guard. The TypeScript side has had these rejection cases since #509
    // (src/lib/fixtureShape.test.ts); this is the Swift half.
    //
    // Note what is deliberately NOT tested: "a v1 file carrying a v2 field". Swift's Codable ignores
    // unknown keys by design, so it cannot reject that, and pretending otherwise would be a test that
    // asserts a behavior the language does not have. That case is genuinely covered on the TypeScript
    // side, which reads the same committed fixtures. What Swift CAN enforce is the version gate and
    // its required fields, so that is what these prove.

    private func decoding(_ json: String) throws -> PrepResults {
        try PrepResultsDecoder.decode(Data(json.utf8))
    }

    @Test func aVersionAboveTheSupportedRangeIsRejected() {
        let future = #"{"version":99,"generatedAt":"now","results":[]}"#
        #expect(throws: PrepResultsError.unsupportedVersion(99)) { try decoding(future) }
    }

    // The gate is a closed RANGE, so it has a floor as well as a ceiling. A version 0 file is not a
    // very old file, it is a broken one.
    @Test func aVersionBelowTheSupportedRangeIsRejected() {
        let ancient = #"{"version":0,"generatedAt":"now","results":[]}"#
        #expect(throws: PrepResultsError.unsupportedVersion(0)) { try decoding(ancient) }
    }

    // naturalKey is the OPAQUE token the run must echo back verbatim. A result without one cannot be
    // matched to any prospect, so it must fail loudly rather than decode into a keyless orphan.
    @Test func aResultMissingItsNaturalKeyIsRejected() {
        let keyless = #"{"version":6,"generatedAt":"now","results":[{"draft":{"subject":"s","body":"b"}}]}"#
        #expect(throws: (any Error).self) { try decoding(keyless) }
    }

    @Test func aFileMissingItsVersionIsRejected() {
        #expect(throws: (any Error).self) { try decoding(#"{"generatedAt":"now","results":[]}"#) }
    }

    @Test func garbageIsRejectedRatherThanReadAsEmpty() {
        #expect(throws: (any Error).self) { try decoding("this is not json at all") }
    }
}
