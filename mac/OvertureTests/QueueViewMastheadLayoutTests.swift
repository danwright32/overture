import Testing
import SwiftUI
@testable import Overture

// #379: layout regression coverage for QueueView's masthead, the second consumer the issue named.
// Same technique and reasoning as ProspectRowViewLayoutTests: relative rendered height, not a
// pixel-diff against a checked-in reference image.
@MainActor
@Suite("QueueView masthead layout (#379)")
struct QueueViewMastheadLayoutTests {
    private static let mastheadWidth: CGFloat = 760

    private func renderedHeight(_ view: some View) -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: Self.mastheadWidth).background(Color.white))
        renderer.scale = 1
        return CGFloat(renderer.cgImage?.height ?? 0)
    }

    private func longshotItem(id: String) -> QueueItem {
        QueueItem(id: id, groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 4, tier: "long_shot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    private func highFitItem(id: String) -> QueueItem {
        QueueItem(id: id, groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil, status: .new)
    }

    @Test func aMastheadWithNoHighFitItemsRendersWithoutTheBreakdownLine() {
        let view = QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
        let items = [longshotItem(id: "a"), longshotItem(id: "b")]

        #expect(renderedHeight(view.masthead(visible: items, items: items)) > 0)
    }

    // Proves the conditional breakdown line (#92/#335: "Of the N high-fit: ...") actually shows
    // when there's a high-fit item to break down, instead of silently never appearing.
    @Test func aMastheadWithAHighFitItemRendersMeaningfullyTallerThanOneWithout() {
        let view = QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
        let withoutHighFit = [longshotItem(id: "a"), longshotItem(id: "b")]
        let withHighFit = [highFitItem(id: "a"), longshotItem(id: "b")]

        let baseline = renderedHeight(view.masthead(visible: withoutHighFit, items: withoutHighFit))
        let withBreakdown = renderedHeight(view.masthead(visible: withHighFit, items: withHighFit))

        #expect(baseline > 0)
        #expect(withBreakdown > baseline)
    }
}
