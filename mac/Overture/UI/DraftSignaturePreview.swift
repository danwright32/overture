import SwiftUI
import WebKit

// #1203: the draft-review card previews the outgoing message as the recipient sees it. When the
// signature carries HTML (GmailMessage.previewHTML), render that styled text/html in a web view so the
// preview matches a rich mail client, instead of the plain-text sign-off. It shows the plain-text
// composition until the styled render is ready (progressive upgrade, so there is never a blank or a bare
// spinner), and falls back to plain text permanently if the render fails, so Dan always sees the body.
struct DraftSignaturePreview: View {
    let draftBody: String
    let signature: OutboundSignature

    @State private var height = PreviewCardHeight()
    @State private var didFail = false

    var body: some View {
        // copy-inventory:ignore-start  renders the outbound email's own HTML (body + Gmail signature), not Overture's voice (#1203)
        if let html = GmailMessage.previewCardHTML(body: draftBody, signature: signature), !didFail {
            ZStack(alignment: .topLeading) {
                SignatureWebView(html: html, height: $height, didFail: $didFail)
                    .frame(height: max(height.points, 1))
                    .opacity(height.hasMeasured ? 1 : 0)
                if !height.hasMeasured { plainText }   // shown until the styled render measures its height
            }
        } else {
            plainText
        }
        // copy-inventory:ignore-end
    }

    private var plainText: some View {
        Text(GmailMessage.previewBody(body: draftBody, signature: signature))
            .font(OVType.body).foregroundStyle(OVColor.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// #2062: how the preview learns how tall it is.
//
// It used to ask once, when the page finished loading, and freeze the answer. A send re-renders the queue
// and so rebuilds the remaining cards' web views; on 2026-08-04 one of those loads finished before SwiftUI
// had given the view its width, the page measured itself at a sliver of a viewport where the email wraps
// to about a word per line, and that height was locked in. Dan got a card with two screens of blank space
// under the email.
//
// The page now reports its height whenever it changes, and it reports the CARD's height rather than the
// document's. Both halves matter: a document's scroll height can never fall below the viewport showing it,
// so even a re-measure of that number could only ever ratchet upwards, never shrink back.
enum PreviewCardMeasure {
    // The channel the page posts through. Paired with `script` below; the web view registers both.
    static let messageHandlerName = "overturePreviewHeight"

    // Injected at document end, so the card exists by the time this runs. ResizeObserver fires once on
    // observe() and then on every size change, which covers all three moments that used to be missed:
    // the first layout, the window widening, and a signature image finishing loading.
    //
    // copy-inventory:ignore-start  browser-side measuring script, not a sentence Overture says to Dan (#915)
    static var script: String {
        """
        (function() {
          var card = document.getElementById("\(GmailMessage.previewCardElementID)");
          if (!card) { return; }
          var report = function() {
            var pad = parseFloat(getComputedStyle(document.body).paddingTop) || 0;
            var height = card.getBoundingClientRect().height + pad * 2;
            if (height > 0) {
              window.webkit.messageHandlers.\(messageHandlerName).postMessage(height);
            }
          };
          if (window.ResizeObserver) { new ResizeObserver(report).observe(card); }
          window.addEventListener("load", report);
          report();
        })();
        """
    }
    // copy-inventory:ignore-end

    // What a posted message means. nil is "no measurement", never a number: a page that reports nothing
    // usable must leave the last good height standing rather than collapse the card Dan is reading (L50,
    // a parsed value never feeds a comparison directly). Rounded up, so a fractional height cannot clip
    // the last line of the email.
    static func height(from message: Any) -> CGFloat? {
        guard let number = message as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return nil }
        return CGFloat(value.rounded(.up))
    }
}

// The height the preview is currently showing, and the rule for changing it. Its whole job is that a
// later measurement REPLACES an earlier one in both directions: the card really is shorter once the text
// stops wrapping, and a preview that could only grow is the defect.
struct PreviewCardHeight {
    private(set) var points: CGFloat = 0
    // Until something has measured, the parent shows the plain-text composition. Nothing measured is not
    // the same as zero tall.
    var hasMeasured: Bool { points > 0 }

    mutating func report(_ message: Any) {
        guard let measured = PreviewCardMeasure.height(from: message) else { return }
        points = measured
    }
}

// A self-sizing web view for the outgoing message's text/html part. Reports its content height back
// through the binding whenever that height changes (#2062); flips `didFail` on a load error so the parent
// can fall back to plain text (fail visible, never a blank block).
private struct SignatureWebView: NSViewRepresentable {
    let html: String
    @Binding var height: PreviewCardHeight
    @Binding var didFail: Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // #2062: the page measures itself and posts every time its height changes, instead of being asked
        // once when the load finishes. That single question raced SwiftUI's layout and lost, freezing the
        // height the email had at a sliver of a width.
        configuration.userContentController.add(context.coordinator,
                                                name: PreviewCardMeasure.messageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: PreviewCardMeasure.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // #1203: transparent, so the light email CARD (previewCardHTML) floats on Overture's dark chrome rather than a full white slab
        context.coordinator.loadedHTML = html
        web.loadHTMLString(html, baseURL: nil)
        return web
    }

    // The handler is retained by the content controller, which the web view owns, so it has to be let go
    // when the view does or the coordinator outlives its view for the life of the process.
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(
            forName: PreviewCardMeasure.messageHandlerName)
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Reload only when the drafted HTML actually changes, never on a height-driven SwiftUI update,
        // or the measure->resize->update cycle would reload forever.
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: SignatureWebView
        var loadedHTML: String?
        init(_ parent: SignatureWebView) { self.parent = parent }

        // Every height the page reports, for as long as it is on screen. PreviewCardHeight owns what to
        // do with each one, including refusing the ones that say nothing.
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == PreviewCardMeasure.messageHandlerName else { return }
            parent.didFail = false
            parent.height.report(message.body)
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.didFail = true
        }

        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.didFail = true
        }
    }
}
