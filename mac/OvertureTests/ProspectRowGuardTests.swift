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

// A dismissed prospect (only ever shown in Archive; the Queue never renders one) reads as
// Dismissed with a Restore action, not as an undecided new prospect with Keep/Dismiss.
@Suite("Dismissed rows show Restore instead of Keep/Dismiss")
struct ProspectRowRestoreGuardTests {
    private var prospectRow: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }

    @Test func onRestoreParameterExists() {
        #expect(!prospectRow.isEmpty)
        #expect(prospectRow.contains("var onRestore: (() -> Void)?"))
    }

    @Test func actionsBranchesOnDismissedStatusBeforeKeepDismiss() {
        guard let actionsRange = prospectRow.range(of: "private var keepDismissControls: some View {") else {
            Issue.record("keepDismissControls view not found")
            return
        }
        let body = prospectRow[actionsRange.lowerBound...].prefix(1600)
        #expect(body.contains("item.status == .dismissed"))
        #expect(body.contains("Restore"))
    }

    // #864: a show Overture retired because its date passed is stored as dismissed, so it would fall into
    // the Restore branch above and offer a button that the next launch silently undoes. Its own branch
    // has to come FIRST. Order is the whole guarantee here, so the guard checks the order, not just that
    // both branches exist.
    @Test func aRetiredShowIsBranchedOnBeforeTheRestoreBranch() {
        guard let actionsRange = prospectRow.range(of: "private var keepDismissControls: some View {") else {
            Issue.record("keepDismissControls view not found")
            return
        }
        let body = String(prospectRow[actionsRange.lowerBound...].prefix(1600))
        guard let wentBy = body.range(of: "item.dismissReason == .wentBy"),
              let dismissed = body.range(of: "item.status == .dismissed") else {
            Issue.record("expected both the went-by branch and the dismissed branch in actions")
            return
        }
        #expect(wentBy.lowerBound < dismissed.lowerBound,
                "a retired show must be caught before the Restore branch, or it offers a Restore that undoes itself")
        #expect(!body.contains("Went by\", systemImage: \"archivebox\""))
    }

    @Test func dismissMenuIsNotNestedInElseIfKept() {  // #499 regression
        guard let actionsRange = prospectRow.range(of: "private var keepDismissControls: some View {") else {
            Issue.record("keepDismissControls view not found")
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

    // #901 (Dan's walk, 2026-07-14): the "Unavailable" badge belongs UP by Keep/Dismiss, not buried in
    // the faint left-hand tag stack where he walked past it. It lives in `actions` (which stacks the badge
    // over `keepDismissControls`), gated on hasUnclearedConflict, tappable to clear. The guard pins the
    // placement, because a badge that drifts back down into the metadata is invisible again.
    @Test func theUnavailableBadgeSitsInTheActionsColumn() {
        guard let actionsRange = prospectRow.range(of: "private var actions: some View {") else {
            Issue.record("actions view not found")
            return
        }
        let body = String(prospectRow[actionsRange.lowerBound...].prefix(1500))
        #expect(body.contains("item.hasUnclearedConflict"))
        #expect(body.contains("Unavailable"))
        #expect(body.contains("I can shoot this anyway"))
        #expect(body.contains("keepDismissControls"))   // badge stacked above the Keep/Dismiss row
    }
}

// #358: the "Source listing" and "Group website" reference links rendered in the default system
// accent blue, clashing with the forest/gold palette and reading as more important than the
// secondary reference links they are. The links row's own .tint(OVColor.forest) does not actually
// recolor a Link's own text on macOS (tint affects control accents, not Link's text color), so
// each link needs its own explicit override. Scoped to the `links` property body (propertyBody,
// #569) rather than a whole-file contains check, since .foregroundStyle(OVColor.forest) already
// appears 4 times elsewhere in this 470-line file for unrelated views.
@Suite("Reference links use the brand palette, not default blue")
struct ReferenceLinkColorGuardTests {
    private var prospectRow: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }

    @Test func sourceListingAndGroupWebsiteLinksHaveTheirOwnBrandColorOverride() {
        #expect(!prospectRow.isEmpty)
        let linksBody = SourceGuardHelper.propertyBody("private var links: some View {", in: prospectRow)
        #expect(linksBody != nil)
        #expect(linksBody?.contains("Link(\"Source listing\"") == true)
        #expect(linksBody?.contains("Link(\"Group website\"") == true)
        // Two links, each with its own override: a shared .tint() further down the modifier
        // chain doesn't reach either Link's own text color.
        let overrideCount = (linksBody?.components(separatedBy: ".foregroundStyle(OVColor.forest)").count ?? 1) - 1
        #expect(overrideCount == 2)
    }
}
