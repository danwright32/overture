import Foundation
import WebKit

// #806: load a page the way a BROWSER does, let its JavaScript run, and hand back the finished page.
//
// This is what stands between Dan and his own ensemble's site. `secondendingensemble.com` is a Wix site:
// what a plain download returns is a navigation shell ("Home / Our Story / Upcoming Events / Contact ...
// Proudly created with Wix.com") and the shows simply are not in those bytes. They exist only after the
// site's scripts run. Small arts organizations live on Wix and Squarespace, so this is not a rare shape:
// it is a whole class of the orgs he pitches, and the watchlist will meet it constantly.
//
// It is a FALLBACK, never the default. The plain download is tried first and, when it carries something
// readable, the browser is never touched (SourceFetcher). Rendering costs seconds and a whole WebKit
// instance per source, and the watchlist re-checks dozens of sources on a schedule, so "just render
// everything" would quietly make the daily run an order of magnitude slower for no gain on the sources
// that already work.
//
// There is precedent for this in the repo: the scout used a hidden WebKit DOM scrape before
// CarnegieExtractor moved to Carnegie's Algolia API.
@MainActor
enum RenderedPage {
    // A page that has not finished after this is a page we are not going to get. Generous, because a
    // cold WebKit start plus a heavy site is genuinely slow, but bounded, because the scout cannot hang
    // on one source: a source that never renders must fail as a source, not as the whole run.
    static let timeout: TimeInterval = 25

    // How long to let the page keep working AFTER navigation finishes. A site-builder calendar is often
    // fetched by script after the document loads, so snapshotting the instant navigation completes would
    // catch the same empty shell we already have and defeat the entire point.
    static let settleAfterLoad: TimeInterval = 2.5

    static func html(for url: URL) async throws -> String {
        let loader = PageLoader()
        return try await loader.load(url, timeout: timeout, settle: settleAfterLoad)
    }
}

// The WKWebView plumbing, kept separate so RenderedPage stays a readable statement of intent.
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func load(_ url: URL, timeout: TimeInterval, settle: TimeInterval) async throws -> String {
        let config = WKWebViewConfiguration()
        // A calendar is HTML and script; it needs neither sound nor autoplaying video, and an offscreen
        // view has nowhere to put them anyway.
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 2000), configuration: config)
        view.navigationDelegate = self
        // Some sites serve a stripped page (or nothing) to a client they do not recognize.
        view.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView = view

        // A page that never finishes loading is a page we are not going to get. The scout cannot hang on
        // one source: a source that never renders must fail as a SOURCE, not as the whole run.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self.resume(throwing: SourceFetchError.unreachable)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
            view.load(URLRequest(url: url))
        }

        // Let the page's own scripts finish building the calendar before we look at it.
        try? await Task.sleep(for: .seconds(settle))

        let html = try await view.evaluateJavaScript("document.documentElement.outerHTML") as? String
        webView = nil
        guard let html else { throw SourceFetchError.unreachable }
        return html
    }

    private func resume(throwing error: Error?) {
        guard !finished else { return }        // navigation delegates can fire more than once
        finished = true
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resume(throwing: nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resume(throwing: SourceFetchError.unreachable) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in self.resume(throwing: SourceFetchError.unreachable) }
    }
}
