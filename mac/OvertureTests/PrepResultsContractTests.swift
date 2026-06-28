import Testing
import Foundation
@testable import Overture

// The Swift reader half of the Prep results contract (#157). The WRITER is the Prep Claude Code
// workflow (docs/prep-runbook.md), not code, so there is no second programmatic side to assert —
// this fixture pins the Swift decode and is the canonical example the runbook points the workflow
// at. A change to PrepResults' shape breaks this test, forcing the runbook + fixture to update in
// lockstep instead of the workflow silently writing a file the app can't ingest (the #109 class).
@Suite("Prep results contract fixtures")
struct PrepResultsContractTests {
    private func fixture(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
        return try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/prep-results/\(name)"))
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
}
