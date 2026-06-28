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

    @Test func decodesTheV1FixtureToTheAgreedLogicalShape() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v1.json"))
        #expect(results.version == 1)
        #expect(results.results.count == 4)

        // Full result: named decision-maker contact + a drafted email with a recorded variant.
        let full = results.results[0]
        #expect(full.naturalKey == "aurora-strings|2026-03-10|carnegie-hall")
        #expect(full.contact?.name == "Emma Robinson")
        #expect(full.contact?.method == "named_decision_maker")
        #expect(full.contact?.confidence == "high")
        #expect(full.draft?.subject == "Photographing Aurora Strings at Carnegie Hall.")
        #expect(full.draft?.variant == "rate_stated")

        // Contact found but no draft yet: contact present with its own optionals nil, draft absent.
        let contactOnly = results.results[1]
        #expect(contactOnly.contact != nil)
        #expect(contactOnly.contact?.name == nil)
        #expect(contactOnly.contact?.method == "generic_inbox")
        #expect(contactOnly.contact?.email == "info@lumendance.example")
        #expect(contactOnly.draft == nil)

        // Bare result (key echoed, nothing found): both contact and draft absent.
        let bare = results.results[2]
        #expect(bare.naturalKey == "unmatched|key|here")
        #expect(bare.contact == nil)
        #expect(bare.draft == nil)
    }

    // The act has no published email, only a contact form (#368, the Ivalas Quartet case). The
    // contract must carry a form-only contact: a contactForm method with a formUrl and NO email,
    // so the app can surface the form as the way to reach the act instead of falling back to a
    // venue inbox. Pins that this shape round-trips through PrepResults.
    @Test func decodesAFormOnlyActContact() throws {
        let results = try PrepResultsDecoder.decode(try fixture("v1.json"))
        let formOnly = results.results[3]
        #expect(formOnly.naturalKey == "ivalas-quartet|2026-07-01|madison-square-park")
        #expect(formOnly.contact?.method == "form_or_dm")
        #expect(formOnly.contact?.confidence == "low")
        #expect(formOnly.contact?.email == nil)
        #expect(formOnly.contact?.formUrl == "https://www.ivalasquartet.com/contact")
    }
}
