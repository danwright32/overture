import Foundation

// Parses Overture's `overture://lead?key=<naturalKey>` deep links (#236), the inverse of
// OmniFocusSync.deepLink(for:). A tapped OmniFocus follow-up task opens this URL; the app routes it
// to the matching prospect. URLComponents percent-decodes the query value, so the returned key is the
// exact stored naturalKey.
enum OvertureDeepLink {
    static let scheme = "overture"
    static let leadHost = "lead"
    static let leadsHost = "leads"
    static let showHost = "show"

    // #282: `overture://show` asks the resident copy to surface its main window. The build script
    // opens this instead of re-launching the bundle, so it routes to the already-running instance
    // rather than spawning a second copy the store lock would refuse.
    static func isShowCommand(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == showHost
    }

    // #301: the inverse of leadKey(from:): build the deep link a tapped notification opens to jump to
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

    // #308: a coalesced multi-lead away alert routes to `overture://leads?key=k1&key=k2…`, carrying the
    // whole set of new-lead keys so the tap can filter the queue to exactly those leads. Repeated `key`
    // query items keep this the natural plural of the singular `lead` host (#236), which stays untouched
    // for the single-lead OmniFocus/away tap. Empty keys are dropped; nil when none remain.
    static func leadsURL(forKeys keys: [String]) -> URL? {
        let nonEmpty = keys.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = leadsHost
        components.queryItems = nonEmpty.map { URLQueryItem(name: "key", value: $0) }
        return components.url
    }

    // The inverse of leadsURL(forKeys:): recover the ordered, non-empty key set a tapped multi-lead
    // alert carried. nil for the wrong scheme/host or when no keys are present.
    static func leadKeys(from url: URL) -> [String]? {
        guard url.scheme == scheme, url.host == leadsHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        let keys = items.filter { $0.name == "key" }.compactMap(\.value).filter { !$0.isEmpty }
        return keys.isEmpty ? nil : keys
    }
}
