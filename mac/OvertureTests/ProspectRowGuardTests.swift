import Testing
import Foundation

// First-use QA polish (#341): the "unsure call" indicator's icon read as a bare system
// glyph rather than an intentional, first-class treatment. View-only change with no
// behavioral surface, held in place with a source guard rather than a runtime assertion.
@Suite("Unsure-call indicator reads as a deliberate treatment, not a system glyph")
struct ProspectRowGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    @Test func unsureCallIconIsNoLongerTheBareDiamondGlyph() {  // #341
        let prospectRow = source("Overture/UI/ProspectRowView.swift")
        #expect(!prospectRow.isEmpty)
        #expect(!prospectRow.contains("questionmark.diamond.fill"))
    }

    @Test func unsureCallIconUsesADeliberateHierarchicalTreatment() {  // #341
        let prospectRow = source("Overture/UI/ProspectRowView.swift")
        #expect(!prospectRow.isEmpty)
        #expect(prospectRow.contains("questionmark.circle.fill"))
        #expect(prospectRow.contains(".symbolRenderingMode(.hierarchical)"))
    }
}
