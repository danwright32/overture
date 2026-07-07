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

// #348: keeping a prospect whose classification is still unconfirmed surfaces the confirm/fix
// choices right away (a popover, since a native Menu can't be opened programmatically), instead
// of silently carrying the unconfirmed guess forward. Dan's call: don't block the keep itself.
@Suite("Keeping an unconfirmed prospect surfaces classification confirm")
struct AutoConfirmClassificationGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var prospectRow: String { source("Overture/UI/ProspectRowView.swift") }

    @Test func keepChecksUncertaintyBeforeShowingTheConfirmPopover() {
        #expect(!prospectRow.isEmpty)
        #expect(prospectRow.contains("showConfirmClassification"))
        #expect(prospectRow.contains("item.isClassificationUncertain"))
    }

    @Test func aPopoverIsWiredToThatState() {
        #expect(prospectRow.contains(".popover(isPresented: $showConfirmClassification)"))
    }

    @Test func thePopoverOffersTheSameThreeResolutions() {
        guard let popoverRange = prospectRow.range(of: ".popover(isPresented: $showConfirmClassification)") else {
            Issue.record("Confirm popover not wired")
            return
        }
        // The popover's content view is defined nearby; search the whole file for the three
        // resolution actions it must offer (reusing the same closures as the manual menu).
        let content = prospectRow[popoverRange.lowerBound...]
        #expect(content.contains("This looks right"))
        #expect(content.contains("onMarkConfidenceReviewed"))
        #expect(content.contains("Self-produced"))
        #expect(content.contains("Agency/presented"))
        #expect(content.contains("Discipline.allCases"))
    }
}

// #NEW: a dismissed prospect (only ever shown in Archive; the Queue never renders one) reads as
// Dismissed with a Restore action, not as an undecided new prospect with Keep/Dismiss.
@Suite("Dismissed rows show Restore instead of Keep/Dismiss")
struct ProspectRowRestoreGuardTests {
    private var prospectRow: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }

    @Test func onRestoreParameterExists() {
        #expect(!prospectRow.isEmpty)
        #expect(prospectRow.contains("var onRestore: (() -> Void)?"))
    }

    @Test func actionsBranchesOnDismissedStatusBeforeKeepDismiss() {
        guard let actionsRange = prospectRow.range(of: "private var actions: some View {") else {
            Issue.record("actions view not found")
            return
        }
        let body = prospectRow[actionsRange.lowerBound...].prefix(600)
        #expect(body.contains("item.status == .dismissed"))
        #expect(body.contains("Restore"))
    }

    @Test func dismissMenuIsNotNestedInElseIfKept() {  // #499 regression
        guard let actionsRange = prospectRow.range(of: "private var actions: some View {") else {
            Issue.record("actions view not found")
            return
        }
        // The regression would show up as "} else if item.isKept {" at the top level of
        // the action's if-else tree, which would scope the Dismiss menu only to the final
        // else block (keeping it from dismissed and kept prospects alike). The fixed
        // structure uses a nested "if item.isKept { } else { }" inside a single outer
        // else, which does not contain that fragment at the method level.
        let body = prospectRow[actionsRange.lowerBound...]
        #expect(!body.contains("} else if item.isKept {"))
    }
}
