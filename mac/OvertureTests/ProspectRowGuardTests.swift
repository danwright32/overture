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
    // host the editor is gone. #4113: it is a dropdown on that line, never a popover again. The popover
    // built its own window and re-laid out the screen on every open (about a second, measured on #4113),
    // which a menu tracked by AppKit does not do.
    @Test func theGenreLineIsADropdownRatherThanAPopover() {
        guard let labelRange = prospectRow.range(of: "QueueModel.disciplineLabel(item.discipline).uppercased()") else {
            Issue.record("Genre line not found in the header")
            return
        }
        let around = prospectRow[..<labelRange.lowerBound].suffix(1400)
        #expect(around.contains("Menu {"))
        #expect(around.contains("selection: genreChoice"))
        #expect(!prospectRow.contains("showGenreEditor"))
        #expect(!prospectRow.contains(".popover(isPresented: $showGenreEditor)"))
    }

    // #4113, Dan's call on seeing the pictures (2026-09-25, in the working session): the chevron sits
    // AFTER the genre word, "DANCE" then the chevron, where it was before. A borderless menu draws its own
    // indicator after the label, and moves any image IN the label in front of the text, so the order holds
    // only while the label is the word alone and the indicator is left showing. The first draft hid the
    // indicator and drew its own chevron, which rendered as a black chevron BEFORE the genre.
    @Test func theChevronFollowsTheGenreWord() {
        guard let labelRange = prospectRow.range(of: "QueueModel.disciplineLabel(item.discipline).uppercased()"),
              let styleRange = prospectRow[labelRange.upperBound...].range(of: ".menuStyle(.borderlessButton)")
        else {
            Issue.record("Genre dropdown label not found in the header")
            return
        }
        let label = prospectRow[labelRange.lowerBound..<styleRange.lowerBound]
        let after = prospectRow[labelRange.upperBound...].prefix(900)
        let before = prospectRow[..<labelRange.lowerBound].suffix(120)
        #expect(!label.contains("Image("), "an image in a borderless menu's label is drawn BEFORE the word")
        #expect(!before.contains("Image("), "an image in a borderless menu's label is drawn BEFORE the word")
        #expect(!after.contains(".menuIndicator(.hidden)"), "the chevron after the word IS the menu indicator")
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

    // An unchanged pick must write nothing. Setting the override flag on a choice that changed nothing
    // would tell every later scout to stop refreshing a genre Dan never actually corrected. #4113: the
    // choice itself is the decision now, so there is no Save; `GenreDropdownTests` drives it.
    @Test func aChoiceRoutesThroughTheResolverSoAnUnchangedPickWritesNothing() {
        #expect(prospectRow.contains("ClassificationResolution.resolve"))
        #expect(prospectRow.contains("case let .correct(discipline)"))
        #expect(!prospectRow.contains("Button(\"Save\")"))
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
        guard let wentBy = body.range(of: "item.showOutcome == .wentBy"),
              let dismissed = body.range(of: "item.status == .dismissed") else {
            Issue.record("expected both the went-by branch and the dismissed branch in actions")
            return
        }
        #expect(wentBy.lowerBound < dismissed.lowerBound,
                "a retired show must be caught before the Restore branch, or it offers a Restore that undoes itself")
        // #4136: and the kept sibling, which is stored dismissed in exactly the same way.
        let unpitched = body.range(of: "item.showOutcome == .wentByUnpitched")
        #expect(unpitched != nil && unpitched!.lowerBound < dismissed.lowerBound,
                "a kept show the calendar closed must be caught before the Restore branch too")
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
        //
        // #3622: which sentence the card shows moved to `QueueModel.cardConflictNote`, so the view must ask
        // it, and the rule there must still read `hasConflict` rather than the gate. The behaviour itself is
        // pinned by `LaterNightStaysOffTheCardTests.anAcceptedClashOnItsOwnNightStillShows`.
        #expect(body.contains("QueueModel.cardConflictNote(item)"))
        let model = SourceGuardHelper.source("Overture/UI/QueueView+Model.swift")
        let rule = model.components(separatedBy: "static func cardConflictNote(").dropFirst().first ?? ""
        #expect(rule.prefix(400).contains("guard item.hasConflict"))
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

// #358: the reference link rendered in the default system accent blue, clashing with the forest/gold
// palette and reading as more important than the secondary link it is. The links row's own
// .tint(OVColor.forest) does not actually recolor a Link's own text on macOS (tint affects control
// accents, not Link's text color), so the link needs its own explicit override. Scoped to the `links`
// property body (propertyBody, #569) rather than a whole-file contains check, since
// .foregroundStyle(OVColor.forest) already appears several times elsewhere in this file for unrelated
// views.
//
// #1640: there were TWO links here, and the second was "Group website". It was drawn from
// `Prospect.websiteURL`, whose only writer anywhere was a literal `nil`, so it had never rendered on any
// card in this app's life. Both it and the field are gone, and the count below moved from two to one with
// them. Kept as a count rather than loosened to "at least one", because the number is the assertion: it
// is what would notice a third link arriving with no override of its own.
@Suite("Reference links use the brand palette, not default blue")
struct ReferenceLinkColorGuardTests {
    private var prospectRow: String { SourceGuardHelper.source("Overture/UI/ProspectRowView.swift") }

    @Test func theSourceListingLinkHasItsOwnBrandColorOverride() {
        #expect(!prospectRow.isEmpty)
        let linksBody = SourceGuardHelper.propertyBody("private var links: some View {", in: prospectRow)
        #expect(linksBody != nil)
        // #1680: the listing link's LABEL is now computed (it says whether the link goes to the show or
        // only to the venue's calendar), so this pins the link itself rather than the literal text. The
        // wording is pinned where wording belongs, in QueueModel.listingLinkLabel's own tests.
        #expect(linksBody?.contains("Link(QueueModel.listingLinkLabel(item)") == true)
        #expect(linksBody?.contains("Group website") == false,
                "the Group website link is back, and the field it drew from was deleted in #1640")
        // #2264: the text-safe green, which is what a Link's own label needs.
        let overrideCount = (linksBody?.components(separatedBy: ".foregroundStyle(OVColor.forestText)").count ?? 1) - 1
        #expect(overrideCount == 1)
    }
}
