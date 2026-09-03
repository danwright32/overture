import Testing
import Foundation
import AppKit
import WebKit
@testable import Overture

// #2062, the half no pure test can make: the preview really does report its height again when its width
// changes, in a real web view rendering the real card HTML.
//
// This is the defect's own shape. The card was measured once, when its page finished loading, and the
// send that re-rendered the queue rebuilt the web view so that the load won the race against SwiftUI's
// layout: the page measured itself at a sliver of a viewport, where the email wraps to about a word per
// line, and that height was frozen. Every model test passed the whole time it was happening, because
// nothing anywhere loaded the document and looked at what it said about itself.
//
// @MainActor: web views and windows are main-actor only.
@MainActor
@Suite("The draft preview re-measures when its width changes (#2062)")
struct PreviewCardMeasureLiveTests {
    // Collects what the page posts back, so a test can wait for the NEXT report rather than guess a delay.
    private final class Collector: NSObject, WKScriptMessageHandler {
        private(set) var heights: [CGFloat] = []

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if let height = PreviewCardMeasure.height(from: message.body) { heights.append(height) }
        }

        // Waits for the reports to stop arriving, and answers with the last one. Returns nil rather than
        // hanging, so a mechanism that never reports fails as a failure and not as a stuck suite.
        func settled(timeout: TimeInterval = 15) async -> CGFloat? {
            let deadline = Date().addingTimeInterval(timeout)
            var seen = -1
            while Date() < deadline {
                if !heights.isEmpty, heights.count == seen { return heights.last }
                seen = heights.count
                try? await Task.sleep(for: .milliseconds(300))
            }
            return nil
        }

        // Waits for a report that arrives AFTER the given count, so a test can tell a fresh measurement
        // from the ones the page had already made.
        func report(after count: Int, timeout: TimeInterval = 15) async -> CGFloat? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if heights.count > count { return heights.last }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
    }

    private let signature = OutboundSignature(
        html: "<div><span style=\"color:#0f766e\">Dan Wright</span> (he/him)</div>"
            + "<div>Dan Wright Photography, New York</div>",
        plainText: "Best,\nDan Wright\nDan Wright Photography")

    private let body = """
        Hi Emma,

        I photograph performing arts in New York, mostly concert and theatre work, and I was reading \
        about your run at The Green Room 42 next week. I would love to shoot one of the nights and \
        send you a set of images you can use for press and for the next season's marketing.

        Would either of the first two nights suit you?
        """

    @Test func aCardMeasuredAtASliverOfAWidthReportsAgainWhenItGetsItsRealWidth() async throws {
        let html = try #require(GmailMessage.previewCardHTML(body: body, signature: signature))
        let collector = Collector()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(collector, name: PreviewCardMeasure.messageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: PreviewCardMeasure.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))

        // Born at a sliver, exactly as the web view is when SwiftUI has not yet given it a width.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 90, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // #3480: AppKit's default is TRUE, so `close()` below RELEASES a window this scope still holds.
        // It has not bitten here, but it did in RealScrollInvalidationTests, where it crashed the SHARED
        // app host and truncated the whole hosted target while naming no test at all.
        window.isReleasedWhenClosed = false
        let web = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(web)
        defer {
            configuration.userContentController.removeScriptMessageHandler(
                forName: PreviewCardMeasure.messageHandlerName)
            window.close()
        }

        web.loadHTMLString(html, baseURL: nil)
        let atASliver = try #require(await collector.settled(),
                                     "The page must report its height without being asked.")
        let reportsSoFar = collector.heights.count

        window.setContentSize(NSSize(width: 620, height: 600))
        web.frame = NSRect(x: 0, y: 0, width: 620, height: 600)
        web.layoutSubtreeIfNeeded()
        let atFullWidth = try #require(await collector.report(after: reportsSoFar),
                                       "A width change must produce a fresh measurement.")

        #expect(atASliver > atFullWidth,
                "Wrapped to a sliver the email is far taller; at its real width the card must report the smaller height, not keep the frozen one.")
    }
}
