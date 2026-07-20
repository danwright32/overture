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

    @State private var height: CGFloat = 0
    @State private var didFail = false

    var body: some View {
        // copy-inventory:ignore-start  renders the outbound email's own HTML (body + Gmail signature), not Overture's voice (#1203)
        if let html = GmailMessage.previewCardHTML(body: draftBody, signature: signature), !didFail {
            ZStack(alignment: .topLeading) {
                SignatureWebView(html: html, height: $height, didFail: $didFail)
                    .frame(height: max(height, 1))
                    .opacity(height > 0 ? 1 : 0)
                if height == 0 { plainText }   // shown until the styled render measures its height
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

// A self-sizing web view for the outgoing message's text/html part. Reports its content height back
// through the binding once the load finishes; flips `didFail` on a load error so the parent can fall
// back to plain text (fail visible, never a blank block).
private struct SignatureWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    @Binding var didFail: Bool

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // #1203: transparent, so the light email CARD (previewCardHTML) floats on Overture's dark chrome rather than a full white slab
        context.coordinator.loadedHTML = html
        web.loadHTMLString(html, baseURL: nil)
        return web
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SignatureWebView
        var loadedHTML: String?
        init(_ parent: SignatureWebView) { self.parent = parent }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            web.evaluateJavaScript("document.body.scrollHeight") { [parent] result, _ in
                let measured = (result as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                parent.didFail = false
                parent.height = max(measured, 1)
            }
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.didFail = true
        }

        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.didFail = true
        }
    }
}
