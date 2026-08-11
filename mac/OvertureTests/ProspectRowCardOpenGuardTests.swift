import Testing
import Foundation

// #1643: the whole-card click target, in the one respect a rendered test cannot reach. ViewInspector
// refuses to read accessibility ACTIONS on this OS ("Accessibility actions are currently unavailable for
// inspection"), so whether the enlarged target is announced at all is checkable only from the source.
// What it SAYS is pinned in CardOpenDestinationTests, and that a click on the row opens the listing while
// the row's own controls keep their clicks is proven by rendering in ProspectCardWholeRowClickTests. This
// is the same split #1742 landed on for the genre control's label.
//
// The failure it exists to catch is a quiet one: a hit target that works beautifully with a mouse and is
// invisible to everything else, which is exactly how an accessibility gap ships without anyone noticing.
@Suite("The whole-card target is never mouse-only (#1643)")
struct ProspectRowCardOpenGuardTests {
    private var triageRow: String? {
        SourceGuardHelper.propertyBody("@ViewBuilder private var triageRow: some View {",
                                       in: SourceGuardHelper.source("Overture/UI/ProspectRowView.swift"))
    }

    @Test func theRowThatTakesAClickAlsoAnnouncesWhatItOpens() throws {
        let row = try #require(triageRow, "the card's row target moved or was renamed")

        #expect(row.contains(".onTapGesture { openCardLink(destination) }"))
        #expect(row.contains(".accessibilityAction(named: Text(cardOpenLabel))"),
                "a target reachable only by mouse is half a control")
    }

    // The words are CardOpenCopy's, so the sentence a screen reader speaks is the one the copy inventory
    // records and a person reads in the diff, rather than a string invented at the call site.
    @Test func whatItAnnouncesComesFromTheCopyItIsInventoriedUnder() throws {
        let source = SourceGuardHelper.source("Overture/UI/ProspectRowView.swift")
        #expect(source.contains("CardOpenCopy.accessibilityLabel(show: item.groupName,"))
    }

    // The draft-review panel is deliberately OUTSIDE the target: it is where Dan reads and edits an email
    // before it goes, and a stray click in its margins pulling a browser in front of him would be worse
    // than the defect this fixes. The panel is a sibling of the row inside the card, so the guard is that
    // the row target sits on the row and not on the card that holds both.
    @Test func theDraftPanelIsNotInsideTheRowTarget() throws {
        let row = try #require(triageRow)
        #expect(!row.contains("DraftReviewView("))
    }
}
