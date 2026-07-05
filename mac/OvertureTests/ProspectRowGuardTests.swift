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

// #349: genre and production type are two independent classifications (a show has both, they
// are never alternatives), so the confirm/fix menu must present them as two distinct labeled
// sections instead of one flat single-select list with a bare divider.
@Suite("Unsure-call menu separates genre from production type")
struct UnsureCallMenuGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var prospectRow: String { source("Overture/UI/ProspectRowView.swift") }

    @Test func genreAndProductionAreSeparatelyLabeledSubmenus() {
        #expect(!prospectRow.isEmpty)
        #expect(prospectRow.contains("Menu(\"Genre\")"))
        #expect(prospectRow.contains("Menu(\"Production type\")"))
    }

    // The discipline choices belong inside the Genre submenu, the production choices inside the
    // Production type submenu, not sitting flat in the outer menu alongside them.
    @Test func disciplineChoicesAreNestedInsideTheGenreSubmenu() {
        guard let genreRange = prospectRow.range(of: "Menu(\"Genre\")") else {
            Issue.record("Genre submenu not found")
            return
        }
        let after = prospectRow[genreRange.upperBound...].prefix(300)
        #expect(after.contains("Discipline.allCases"))
    }

    @Test func productionChoicesAreNestedInsideTheProductionSubmenu() {
        guard let productionRange = prospectRow.range(of: "Menu(\"Production type\")") else {
            Issue.record("Production type submenu not found")
            return
        }
        let after = prospectRow[productionRange.upperBound...].prefix(300)
        #expect(after.contains("Self-produced"))
        #expect(after.contains("Agency/presented"))
    }
}
