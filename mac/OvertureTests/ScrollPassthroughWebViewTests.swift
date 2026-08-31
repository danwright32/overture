import Testing
import AppKit
import WebKit

// #2081: the send confirmation's email preview would not scroll. The preview sits inside a
// scroller capped at a fixed height (SendConfirmSheet), but the web view rendering the email
// swallows every scroll wheel gesture over its own area, and since the web view is self-sizing
// (its frame always equals its content height) it never has anywhere to scroll ITSELF. So the
// gesture died inside it, the enclosing scroller never moved, and Dan could not reach his own
// signature on the one screen captioned "The email that will send".
@Suite("Scroll gestures pass through the email preview (#2081)")
struct ScrollPassthroughWebViewTests {

    // Stands in for whatever scrollable container holds the preview. In the app that is the
    // next responder up the chain (a view's next responder is its superview by default).
    private final class ScrollRecorder: NSView {
        private(set) var received = 0
        override func scrollWheel(with event: NSEvent) { received += 1 }
    }

    private func scrollEvent() throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cg))
    }

    // The behavior itself: a wheel gesture delivered to the preview's web view must travel on
    // to the responder above it, because the web view never needs the gesture for itself.
    @Test func aScrollWheelGestureReachesTheResponderAboveTheWebView() throws {
        let recorder = ScrollRecorder(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let web = ScrollPassthroughWebView(frame: recorder.bounds,
                                           configuration: WKWebViewConfiguration())
        recorder.addSubview(web)

        web.scrollWheel(with: try scrollEvent())

        #expect(recorder.received == 1,
                "The gesture must reach the container that can actually scroll, not die inside the web view.")
    }

    // The wiring: the preview must BUILD its web view as the passthrough kind. A correct class
    // nothing instantiates would leave the sheet exactly as broken as before (a guard and its
    // wiring are two separate claims).
    @Test func thePreviewBuildsItsWebViewAsThePassthroughKind() {
        let source = SourceGuardHelper.source("Overture/UI/DraftSignaturePreview.swift")
        let body = SourceGuardHelper.bodyOfFunction(named: "makeNSView", in: source)

        #expect(body?.contains("ScrollPassthroughWebView(frame:") == true,
                "SignatureWebView must instantiate the passthrough subclass.")
        #expect(body?.contains("= WKWebView(") != true,
                "A bare WKWebView here swallows scroll gestures over the preview.")
    }
}
