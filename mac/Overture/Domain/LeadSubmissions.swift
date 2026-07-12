import Foundation

// The links Dan has already handed over (#799).
//
// His rule, and it is a product decision that DELETES a bug rather than patching one (2026-07-12):
//
//   "We just shouldn't allow the same link twice, because if I'm adding a lead that means we should
//    be scouting them regularly. So no need to check it again through that flow."
//
// The bug it removes: the sheet waits for the extract run by reading the results file, and a second
// paste of the SAME link would find the PREVIOUS run's file sitting there under the same id and hand
// back its stale shows instantly, without waiting for the fresh read. He would have seen old results
// with no way to know they were old.
//
// Once a link cannot be submitted twice, that is unreachable. And the right answer to "I already gave
// you this" was never to re-read it: the org belongs on the watchlist, and the watchlist re-checks it.
//
// Deliberately a plain persisted list, not a new @Model. Phase 2 (#800) introduces WatchedSource, which
// is where a submitted lead's ORG will really live; this only has to remember the LINKS he has already
// spent a run on, and inventing a store migration for that ahead of the model that will own it would
// be building the same thing twice.
enum LeadSubmissions {
    static let key = "leadSubmittedURLs"

    static func contains(_ url: URL, in defaults: UserDefaults = .standard) -> Bool {
        stored(in: defaults).contains(canonical(url))
    }

    static func record(_ url: URL, in defaults: UserDefaults = .standard) {
        var all = stored(in: defaults)
        all.insert(canonical(url))
        defaults.set(Array(all), forKey: key)
    }

    private static func stored(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    // The same page, spelled the three ways a person actually pastes it, is the same page: scheme and
    // "www." and a trailing slash and capitalisation are not what makes a link different. Otherwise the
    // rule is defeated by a trailing slash and he re-reads the page he already gave us.
    //
    // The PATH and the QUERY are what distinguish two pages, and both matter: an org's events page and
    // one show's page are different leads he may legitimately hand over, and plenty of season pages are
    // told apart only by "?season=2027".
    static func canonical(_ url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }

        var path = url.path.lowercased()
        while path.hasSuffix("/") { path.removeLast() }

        let query = url.query.map { "?" + $0.lowercased() } ?? ""
        return host + path + query
    }
}
