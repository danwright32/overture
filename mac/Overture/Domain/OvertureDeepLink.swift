import Foundation

// Parses Overture's `overture://lead?key=<naturalKey>` deep links (#236), the inverse of
// OmniFocusSync.deepLink(for:). A tapped OmniFocus follow-up task opens this URL; the app routes it
// to the matching prospect. URLComponents percent-decodes the query value, so the returned key is the
// exact stored naturalKey.
enum OvertureDeepLink {
    static let scheme = "overture"
    static let leadHost = "lead"

    static func leadKey(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == leadHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value,
              !key.isEmpty
        else { return nil }
        return key
    }
}
