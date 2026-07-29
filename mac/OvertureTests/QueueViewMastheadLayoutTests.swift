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

    @Test func aMastheadRendersWithHeight() {
        let view = QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
        let items = [longshotItem(id: "a"), longshotItem(id: "b")]

        #expect(renderedHeight(view.masthead(visible: items, items: items, fanOutLine: nil)) > 0)
    }

    // #1694: the fan-out warning is drawn, not merely computed. Dan's call was that the questions stay on
    // the cards and Overture says separately that one of them looks like a pattern, so "separately" has to
    // be somewhere he actually looks. Asserted by height, because a masthead that swallowed the line would
    // otherwise pass every test that only checked the sentence itself.
    @Test func aFanOutWarningMakesTheMastheadTaller() {
        let view = QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
        let items = [longshotItem(id: "a"), longshotItem(id: "b")]

        let quiet = renderedHeight(view.masthead(visible: items, items: items, fanOutLine: nil))
        let warned = renderedHeight(view.masthead(
            visible: items, items: items,
            fanOutLine: "Carnegie Hall Citywide: Ivalas Quartet is flagged as a possible match on 19 "
                + "shows, which usually means the match is wrong."))

        #expect(quiet > 0)
        #expect(warned > quiet)
    }

    // #1131: the "Of the N high-fit: ..." breakdown line was removed from the masthead. So a high-fit item
    // must no longer make the masthead taller: with the breakdown line gone, the height is the same whether
    // or not a high-fit item is present. If someone re-introduced the breakdown line, this would fail.
    @Test func aHighFitItemNoLongerAddsABreakdownLine() {
        let view = QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
        let withoutHighFit = [longshotItem(id: "a"), longshotItem(id: "b")]
        let withHighFit = [highFitItem(id: "a"), longshotItem(id: "b")]

        let baseline = renderedHeight(view.masthead(visible: withoutHighFit, items: withoutHighFit, fanOutLine: nil))
        let withHigh = renderedHeight(view.masthead(visible: withHighFit, items: withHighFit, fanOutLine: nil))

        #expect(baseline > 0)
        #expect(withHigh == baseline)
    }
}
