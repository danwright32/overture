import Testing
import SwiftUI

// #1461: the shared status pill. The point of extracting it is that the same semantic can no longer read
// at two strengths in two rows, so the two things worth pinning are (1) each tone maps to its expected
// colour, and (2) there is ONE opacity, not the 0.10/0.12/0.14/0.15/0.16 spread that existed before.
@Suite("The shared status pill (#1461)")
struct OVPillTests {

    @Test func eachToneCarriesItsSemanticColour() {
        #expect(OVPillTone.warning.tint == OVColor.rust)
        #expect(OVPillTone.pending.tint == OVColor.gold)
        #expect(OVPillTone.confirmed.tint == OVColor.forest)
        #expect(OVPillTone.neutral.tint == OVColor.inkFaint)
    }

    // One fill opacity for every tone: this is the whole consolidation. If a per-tone opacity ever creeps
    // back, this is the line that has to change, which is the review seam that catches it.
    @Test func thereIsASingleFillOpacityForEveryTone() {
        #expect(OVPillTone.fillOpacity == 0.12)
    }
}

// The drift this issue closed cannot come back quietly: a hand-drawn `Capsule().fill(<tint>.opacity(0.1x))`
// status pill in a row view is exactly the pattern OVPill replaced, so a source guard fails if one returns.
// Scoped to a literal-opacity tint fill, so the solid CTAs (`Capsule().fill(OVColor.forest)`), the variable
// progress/dot fills (`.opacity(isRunning ? …)`), and OVPill's own draw are all left alone.
@Suite("Status pills go through OVPill, not hand-drawn capsules (#1461)")
struct OVPillAdoptionGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    @Test func prospectRowViewDrawsNoHandRolledStatusPill() {
        let body = source("Overture/UI/ProspectRowView.swift")
        for tint in ["rust", "gold", "forest", "inkFaint"] {
            #expect(!body.contains("Capsule().fill(OVColor.\(tint).opacity(0.1"),
                    "ProspectRowView hand-draws an OVColor.\(tint) status pill; use .ovPill(_:) instead")
        }
    }

    @Test func prospectRowViewAdoptedTheSharedPill() {
        // Adoption, not just absence: the pills were converted TO ovPill, not deleted.
        let body = source("Overture/UI/ProspectRowView.swift")
        let count = body.components(separatedBy: ".ovPill(").count - 1
        #expect(count >= 8, "expected the row's status pills to go through .ovPill; found \(count)")
    }
}
