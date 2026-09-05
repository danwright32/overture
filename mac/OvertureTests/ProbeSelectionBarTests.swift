import Testing
import Foundation
import SwiftUI

// #1774: the ticked reachability dates move off QueueView's @State onto a shared object, so that ticking
// a date invalidates the checkbox and the selection bar instead of re-deriving the entire queue.
//
// The whole point of the extraction is that these two views read the LIVE selection. A version that copied
// the ticked dates into the view value at construction would look right in every screenshot, pass every
// test of QueueModel.probeSelection (which ProbeMultiDateSelectionTests already covers thoroughly), and be
// silently dead on screen: Dan would tick a date and nothing would happen. So each test below mutates the
// selection AFTER building the view value, which is the only shape that can tell the two apart.
//
// Rendered-height / rendered-image comparison, the technique QueueViewMastheadLayoutTests and
// ProspectRowViewLayoutTests already use, because this repo has no view-introspection library.
@MainActor
@Suite("The probe selection bar and checkbox read the live selection (#1774)")
struct ProbeSelectionBarTests {
    private static let barWidth: CGFloat = 760
    private let today = "2026-09-01"

    private func item(_ key: String, date: String, presenter: String?, venue: String) -> QueueItem {
        var i = QueueItem(id: key, groupName: key, discipline: "theater", venue: venue,
                          performanceDate: date, sourceListingURL: nil,
                          priorRelationship: "none", production: "self", profile: "strong",
                          coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                          matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                          status: .new)
        i.presenter = presenter
        return i
    }

    private var rows: [QueueItem] {
        [item("a", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks"),
         item("b", date: "2026-09-12", presenter: "Solo Co", venue: "The Tank"),
         item("c", date: "2026-09-13", presenter: "FRIGID New York", venue: "The Kraine Theater")]
    }

    private func renderedHeight(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: Self.barWidth).background(Color.white))
        renderer.scale = 1
        return CGFloat(renderer.cgImage?.height ?? 0)
    }

    private func renderedImage(_ view: some View) -> Data? {
        let renderer = ImageRenderer(content: view.background(Color.white))
        renderer.scale = 1
        return renderer.nsImage?.tiffRepresentation
    }

    private func bar(_ selection: ProbeSelectionState) -> ProbeSelectionBar {
        let captured = rows
        return ProbeSelectionBar(selection: selection, rows: { captured }, allItems: captured,
                                 today: today, stage: .scout, checkRunning: false,
                                 onRun: { _, _, _ in })
    }

    // Nothing ticked is the resting state: the bar draws nothing at all, so it cannot sit over the rows
    // offering to spend on an empty selection.
    @Test func anEmptySelectionDrawsNoBar() {
        #expect(renderedHeight(bar(ProbeSelectionState())) == 0)
    }

    // THE test. The view value is built while nothing is ticked, then the shared object is ticked. A bar
    // holding a copy taken at construction renders the same twice and this goes red.
    @Test func theBarReflectsADateTickedAfterItWasBuilt() {
        let selection = ProbeSelectionState()
        let view = bar(selection)

        let before = renderedHeight(view)
        selection.toggle("2026-09-12")
        let after = renderedHeight(view)

        #expect(before == 0)
        #expect(after > 0)
    }

    // And it goes back when the selection is cleared, so a run that consumed the ticks leaves no bar
    // floating over the rows promising a selection that is gone.
    @Test func clearingTheSelectionTakesTheBarAwayAgain() {
        let selection = ProbeSelectionState()
        let view = bar(selection)
        selection.toggle("2026-09-12")

        let ticked = renderedHeight(view)
        selection.clear()

        #expect(ticked > 0)
        #expect(renderedHeight(view) == 0)
    }

    // The checkbox on the date heading, same property. Compared as rendered images rather than heights
    // because a tick and an empty box are the same size; what changes is which symbol is drawn.
    @Test func theCheckboxShowsATickMadeAfterItWasBuilt() {
        let selection = ProbeSelectionState()
        let view = ProbeDateCheckbox(groupID: "2026-09-12", selection: selection)

        let unticked = renderedImage(view)
        selection.toggle("2026-09-12")
        let ticked = renderedImage(view)

        #expect(unticked != nil)
        #expect(ticked != nil)
        #expect(unticked != ticked)
    }

    // The state object itself. Cheap, and it pins that a second tick on the same date is a removal rather
    // than a no-op, which is what makes the checkbox a toggle instead of a one-way switch.
    @Test func tickingTheSameDateTwiceRemovesIt() {
        let selection = ProbeSelectionState()
        selection.toggle("2026-09-12")
        selection.toggle("2026-09-13")
        #expect(selection.dates == ["2026-09-12", "2026-09-13"])

        selection.toggle("2026-09-12")
        #expect(selection.dates == ["2026-09-13"])
        #expect(selection.contains("2026-09-12") == false)
    }
}
