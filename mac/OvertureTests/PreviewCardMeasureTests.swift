import Testing
import Foundation

// #2062: how tall the draft preview's white card is.
//
// Dan sent one of three shows in Review on 2026-08-04 and the card below it became enormously tall: the
// email preview rendered normally, then roughly two screens of blank dark space before the controls. The
// preview measured its own height exactly once, when its page finished loading, and froze that number.
// The send re-rendered the queue, which rebuilt the remaining card's web view, and this time the page
// finished loading before SwiftUI had given it its real width. It measured itself at a sliver-wide
// viewport, where the email text wraps to about one word per line, and locked in that height.
//
// So the number is now reported continuously rather than once, and it may go DOWN. That second half is
// the part a single re-measure would not have fixed: the old measurement was the document's scroll
// height, which can never report less than the viewport it sits in, so it could only ever ratchet up.
@Suite("The draft preview's height tracks its content (#2062)")
struct PreviewCardMeasureTests {
    // The bug, in one line: a later, smaller measurement wins. A card whose text stops wrapping when the
    // window widens really is shorter, and the preview has to say so.
    @Test func aSmallerLaterMeasurementReplacesALargerOne() {
        var height = PreviewCardHeight()
        height.report(NSNumber(value: 912.0))
        #expect(height.points == 912)

        height.report(NSNumber(value: 243.5))

        #expect(height.points == 244, "A re-measure must be able to shrink the card, not only grow it.")
    }

    // Nothing measured yet is not "zero tall": the parent shows the plain-text composition until a real
    // height arrives, and a zero would let the styled card take its place while empty.
    @Test func nothingIsClaimedUntilSomethingHasBeenMeasured() {
        let height = PreviewCardHeight()
        #expect(height.points == 0)
        #expect(height.hasMeasured == false)
    }

    // The failure path. A page that reports nothing usable must leave the last good height standing
    // rather than collapsing the card to nothing, which would hide the email Dan is about to send.
    @Test func anUnusableReportLeavesTheLastGoodHeightStanding() {
        var height = PreviewCardHeight()
        height.report(NSNumber(value: 243.0))

        height.report(NSNumber(value: 0.0))
        height.report(NSNumber(value: -20.0))
        height.report(NSNumber(value: Double.nan))
        height.report(NSNumber(value: Double.infinity))
        height.report("not a number at all")

        #expect(height.points == 243)
    }

    // A parsed value must never feed a comparison directly (L50): every one of these fails the "is it a
    // usable height" question rather than landing on some permissive side of it.
    @Test func onlyAFinitePositiveNumberCountsAsAMeasurement() {
        #expect(PreviewCardMeasure.height(from: NSNumber(value: 120.2)) == 121)
        #expect(PreviewCardMeasure.height(from: NSNumber(value: 0.0)) == nil)
        #expect(PreviewCardMeasure.height(from: NSNumber(value: Double.nan)) == nil)
        #expect(PreviewCardMeasure.height(from: NSNumber(value: -1.0)) == nil)
        #expect(PreviewCardMeasure.height(from: "600") == nil)
        #expect(PreviewCardMeasure.height(from: [612]) == nil)
    }

    // The script measures the CARD, and the card is emitted by the message composer. Two places naming
    // one element, so they are made to name it through one constant: a rename on either side that broke
    // the other would leave the preview measuring nothing at all, silently.
    @Test func theScriptMeasuresTheElementTheCardHtmlActuallyEmits() {
        let sig = OutboundSignature(html: "<div>Dan Wright</div>", plainText: "Best,\nDan Wright")
        let card = GmailMessage.previewCardHTML(body: "Hi Emma,", signature: sig)

        #expect(card?.contains("id=\"\(GmailMessage.previewCardElementID)\"") == true)
        #expect(PreviewCardMeasure.script.contains(GmailMessage.previewCardElementID))
        #expect(PreviewCardMeasure.script.contains(PreviewCardMeasure.messageHandlerName))
    }

    // Measuring the document's own scroll height is what could not shrink, because a document is never
    // shorter than the viewport showing it. The card element is the content, so its height is the answer.
    @Test func theScriptDoesNotMeasureTheDocumentItself() {
        #expect(PreviewCardMeasure.script.contains("scrollHeight") == false,
                "A document's scroll height can never fall below the viewport, so it cannot report a shrink.")
    }
}
