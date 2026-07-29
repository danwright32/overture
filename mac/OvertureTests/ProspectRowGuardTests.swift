import Testing
import Foundation

// #1533: the row no longer PROMPTS about a classification. The amber "Not sure of the genre or type"
// badge is gone (it named a genre the confidence never measured, and asked for a production type Dan
// does not research), and with it the #348 popover that Keep used to pull up on three quarters of the
// queue. What remains is a correction he reaches for only when he disagrees: the genre line in the
// header, which STATES the genre, opens a one-picker editor.
//
// These are source guards, not behavioral assertions: the wiring lives in a SwiftUI view body, where a
// test can neither tap the control nor read what it rendered. The behavior underneath is proven in
// ClassificationResolutionTests and ClassificationOverrideTests.
@Suite("The row corrects a genre without prompting for one (#1533)")
struct ProspectRowGuardTests {
    private var prospectRow: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }

    @Test func theUnsureBadgeAndItsCopyAreGone() {
        #expect(!prospectRow.isEmpty)
        #expect(!prospectRow.contains("Not sure of the genre or type"))
        #expect(!prospectRow.contains("questionmark.circle.fill"))
        #expect(!prospectRow.contains("isClassificationUncertain"))
    }

    // The crux of #1533, and the thing a well-meaning later edit is most likely to undo: Keep must not
    // reopen a classification editor. It did on every unconfirmed guess, which was 431 of the 556
    // undecided rows on the live store.
    @Test func keepDoesNotOpenAnEditor() {
        guard let keepRange = prospectRow.range(of: "onKeep()") else {
            Issue.record("Keep action not found")
            return
        }
        let around = prospectRow[..<keepRange.lowerBound].suffix(400)
        #expect(!around.contains("showGenreEditor"))
    }

    // The genre line is the control, so a correction stays reachable now that the badge which used to
    // host the editor is gone.
    @Test func theGenreLineOpensTheEditor() {
        guard let labelRange = prospectRow.range(of: "QueueModel.disciplineLabel(item.discipline).uppercased()") else {
            Issue.record("Genre line not found in the header")
            return
        }
        let around = prospectRow[..<labelRange.lowerBound].suffix(400)
        #expect(around.contains("showGenreEditor = true"))
        #expect(prospectRow.contains(".popover(isPresented: $showGenreEditor)"))
    }
}

// #1533: the editor carries the GENRE alone. A production-type picker here would put back the question
// Dan told us he will not answer, and every Discipline case must be offered or a show whose real genre
// is missing from the list could not be corrected at all.
@Suite("The genre editor offers every genre and nothing else")
struct GenreEditorGuardTests {
    private var prospectRow: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }

    @Test func everyGenreIsOffered() {
        #expect(!prospectRow.isEmpty)
        #expect(prospectRow.contains("Discipline.allCases"))
    }

    @Test func thereIsNoProductionTypePicker() {
        #expect(!prospectRow.contains("Production type"))
        #expect(!prospectRow.contains("Agency/presented"))
    }

    // An unchanged pick must write nothing. Setting the override flag on a Save that changed nothing
    // would tell every later scout to stop refreshing a genre Dan never actually corrected.
    @Test func saveRoutesThroughTheResolverSoAnUnchangedPickWritesNothing() {
        #expect(prospectRow.contains("ClassificationResolution.resolve"))
        #expect(prospectRow.contains("case let .correct(discipline)"))
        #expect(prospectRow.contains("Button(\"Save\")"))
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
        // #1501: reads the WHOLE property (the #569 helper this file's other guards use) rather than the
        // first 1500 characters after its declaration. That window silently depended on how much comment sat
        // inside the property: adding two lines of it pushed `keepDismissControls` out of range and failed a
        // guard about placement for a reason that had nothing to do with placement.
        guard let body = SourceGuardHelper.propertyBody("private var actions: some View {",
                                                        in: prospectRow) else {
            Issue.record("actions view not found")
            return
        }
        // #1583: the SENTENCE renders on `hasConflict`, not on the gate, so accepting a clash stops the
        // blocking and not the telling. Reading the gate here is the regression this pins: it would take the
        // clash off the card the instant Dan kept the show, which is the state he most needs to still see.
        #expect(body.contains("item.hasConflict"))
        // #1583: the surviving accept control is gated on the show being KEPT already, because on an
        // untriaged card Keep itself is the acceptance and a second control asks one judgment twice.
        #expect(body.contains("item.hasUnclearedConflict && item.isKept"))
        #expect(body.contains("I can shoot this anyway"))
        #expect(body.contains("keepDismissControls"))   // badge stacked above the Keep/Dismiss row
    }

    // #1527: the badge's COLOUR and hover text now come off that same decision, the way its label already
    // did. Pinned by source because the view is not directly invokable: what the colours ARE is measured in
    // ConflictPillColourTests, and this is the other half, that the view actually asks for them. Without it
    // the pill could keep a hard-coded rust fill while every colour test passed (#1352's "a guard and its
    // wiring are two claims").
    @Test func theConflictSentenceTakesItsColourFromTheSharedDecision() {   // #1527/#1583
        guard let body = SourceGuardHelper.propertyBody("private var actions: some View {",
                                                        in: prospectRow) else {
            Issue.record("actions view not found")
            return
        }
        #expect(body.contains("scope.noteTint"))
        // The defect this issue is about: a fill picked at the call site rather than by the case.
        #expect(!body.contains("OVColor.rust"),
                "the conflict badge is hard-coding the failure colour again instead of asking ConflictScope (#1527).")
        #expect(!body.contains("OVColor.onRust"))
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
        // #1680: the listing link's LABEL is now computed (it says whether the link goes to the show or
        // only to the venue's calendar), so this pins the link itself rather than the literal text. The
        // wording is pinned where wording belongs, in QueueModel.listingLinkLabel's own tests.
        #expect(linksBody?.contains("Link(QueueModel.listingLinkLabel(item)") == true)
        #expect(linksBody?.contains("Link(\"Group website\"") == true)
        // Two links, each with its own override: a shared .tint() further down the modifier
        // chain doesn't reach either Link's own text color.
        let overrideCount = (linksBody?.components(separatedBy: ".foregroundStyle(OVColor.forest)").count ?? 1) - 1
        #expect(overrideCount == 2)
    }
}
