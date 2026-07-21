import Foundation

// #1127: a tickettailor box-office widget embedded in a venue's page (The Cell). The page a plain fetch
// returns is only the widget SHELL; the events are served, as plain HTML, from the tickettailor
// `all-tickets-calendar` URL the shell declares in a `data-url` attribute. That widget URL is fetchable
// with normal browser headers (no Cloudflare challenge, no browser render), so this is a plain,
// deterministic hop, not a render. It is not host-routed like the OPERA/VenueTix feed adapters, because
// tickettailor is embedded in arbitrary venue hosts; instead the fetched page is inspected for the embed.
enum TicketTailor {
    // The tickettailor events widget URL declared in a page's embed, or nil if the page carries no
    // tickettailor box-office calendar embed. Only the `all-tickets-calendar` embed (the events widget)
    // counts; a plain tickettailor link (a "powered by" credit, a promoter link) must not match.
    static func widgetURL(inPage html: String) -> URL? {
        // The events widget URL, wherever it appears (a data-url attribute, an href). The
        // `all-tickets-calendar/<slug>` path is what distinguishes the events embed from a plain
        // tickettailor link, so it is required.
        let pattern = #"https://www\.tickettailor\.com/all-tickets-calendar/[A-Za-z0-9_-]+/?"#
        guard let range = html.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(html[range]))
    }

    // The widget answers a bare fetch with a Cloudflare 403; a full, realistic browser header set returns
    // the server-rendered event HTML (200). These are the headers verified to pass.
    // copy-inventory:ignore-start  an outbound API request's headers, not the app's voice (#915)
    static func widgetRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("iframe", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("cross-site", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("https://www.tickettailor.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 30
        return req
    }
    // copy-inventory:ignore-end

    // Fetches the widget's server-rendered listing and hands it back as a normal page for the extractor to
    // read. A non-200 (the Cloudflare 403, or any outage) THROWS rather than returning an empty page: an
    // empty page would read to the reconcile as "every show was cancelled". `get` is injected for tests.
    static func fetchWidget(_ url: URL,
                            get: (URLRequest) async throws -> (Data, URLResponse)) async throws -> FetchedPage {
        let (data, response) = try await get(widgetRequest(url))
        guard let http = response as? HTTPURLResponse else { throw SourceFetchError.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw SourceFetchError.http(http.statusCode) }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let normalized = PageNormalizer.normalize(html)
        return FetchedPage(normalizedHTML: normalized,
                           finalURL: url.absoluteString,
                           contentHash: PageNormalizer.contentHash(normalized),
                           // #1295: carry the RAW widget bytes so the scout can parse the embedded
                           // selectableDates JSON natively (free), which the normalized HTML cannot (its
                           // <script> is stripped). The content hash stays on the normalized bytes.
                           ticketTailorWidgetHTML: html)
    }
}
