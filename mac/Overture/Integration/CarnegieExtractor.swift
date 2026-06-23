import Foundation
import WebKit

// Loads Carnegie's calendar in a hidden WebKit view (never added to a visible window,
// so nothing pops up) and runs the extractor in the page. WebKit is the real Safari
// engine, so the JS-rendered, bot-protected calendar loads the same as in a browser.
// Returns structured events. The JS mirrors scripts/scout/extract-carnegie.js.

enum CarnegieExtractorError: Error { case timedOut, badResult }

// What the in-page JS returns per event. The venue is resolved from `context` in Swift
// (VenueParser), not in the page, so the venue logic stays testable (#34).
private struct RawCarnegieEvent: Codable {
    var title: String
    var presenter: String?
    var context: String?
    var performanceDate: String?
    var sourceUrl: String?
}

@MainActor
final class CarnegieExtractor: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[ExtractedEvent], Error>?
    private var pollCount = 0

    private let url = URL(string: "https://www.carnegiehall.org/Calendar")!
    private let maxPolls = 15

    func extract() async throws -> [ExtractedEvent] {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
            web.navigationDelegate = self
            self.webView = web
            web.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The events render via JS after load, so poll until they appear.
        pollForEvents()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func pollForEvents() {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.extractorJS) { [weak self] result, _ in
            guard let self else { return }
            if let json = result as? String,
               let data = json.data(using: .utf8),
               let raws = try? JSONDecoder().decode([RawCarnegieEvent].self, from: data),
               !raws.isEmpty {
                // Resolve the venue from the listing context in Swift (testable), broadened
                // beyond Carnegie's named halls (#34).
                let events = raws.map { r in
                    ExtractedEvent(title: r.title, presenter: r.presenter,
                                   venue: r.context.flatMap { VenueParser.parse(context: $0) },
                                   performanceDate: r.performanceDate, sourceUrl: r.sourceUrl)
                }
                self.finish(.success(events))
                return
            }
            self.pollCount += 1
            if self.pollCount >= self.maxPolls {
                self.finish(.failure(CarnegieExtractorError.timedOut))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.pollForEvents()
            }
        }
    }

    private func finish(_ result: Result<[ExtractedEvent], Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        webView?.navigationDelegate = nil
        webView = nil
        cont.resume(with: result)
    }

    private static let extractorJS = #"""
    (function () {
      const anchors = Array.from(document.querySelectorAll('a[href*="/calendar/"]'));
      const seen = new Set();
      const events = [];
      for (const a of anchors) {
        const href = a.getAttribute('href') || '';
        const m = href.match(/\/calendar\/(\d{4})\/(\d{2})\/(\d{2})\//);
        if (!m) continue;
        const title = (a.textContent || '').trim().replace(/\s+/g, ' ');
        if (!title || title.length < 3) continue;
        const key = href.split('?')[0];
        if (seen.has(key)) continue;
        seen.add(key);
        let ctx = a;
        for (let i = 0; i < 4 && ctx.parentElement; i++) ctx = ctx.parentElement;
        const context = (ctx.textContent || '').replace(/\s+/g, ' ').trim();
        const pm = context.match(/Presented by (.+?)(?= [A-Z][a-z]|$)/);
        events.push({
          title: title,
          presenter: pm ? pm[1].trim() : null,
          context: context,
          performanceDate: m[1] + '-' + m[2] + '-' + m[3],
          sourceUrl: key.indexOf('http') === 0 ? key : 'https://www.carnegiehall.org' + key
        });
      }
      return JSON.stringify(events);
    })()
    """#
}
