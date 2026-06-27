import Foundation

// Parses Overture's `overture://lead?key=<naturalKey>` deep links (#236), the inverse of
// OmniFocusSync.deepLink(for:). A tapped OmniFocus follow-up task opens this URL; the app routes it
// to the matching prospect. URLComponents percent-decodes the query value, so the returned key is the
// exact stored naturalKey.
enum OvertureDeepLink {
    static let scheme = "overture"
    static let leadHost = "lead"
    static let showHost = "show"

    // #282: `overture://show` asks the resident copy to surface its main window. The build script
    // opens this instead of re-launching the bundle, so it routes to the already-running instance
    // rather than spawning a second copy the store lock would refuse.
    static func isShowCommand(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == showHost
    }

    // #301: the inverse of leadKey(from:) — build the deep link a tapped notification opens to jump to
    // a lead. URLComponents percent-encodes the key in the query, so leadKey(from:) recovers it exactly.
    // nil for an empty key (no lead to route to).
    static func leadURL(forKey key: String) -> URL? {
        guard !key.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = leadHost
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        return components.url
    }

    static func leadKey(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == leadHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value,
              !key.isEmpty
        else { return nil }
        return key
    }
}
