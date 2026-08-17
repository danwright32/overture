import Foundation

// #2387: which KIND of web lookup a run was refused, said in the sentence Dan reads.
//
// `record_web_calls` has recorded refusals per route since #1835 (`deniedByRoute` in
// `mac/scripts/lib/models.sh`, counting fetch, search, browser and bash), and the sentence threw it
// away: "2 web lookups refused, that research never happened".
//
// The route is the difference between two unrelated pieces of news:
//
//   * a refused BROWSER call is the tool scope holding. The browser is outside `PREP_ALLOWED_TOOLS`
//     under a fail-closed mode deliberately, so this is the runner working exactly as designed and
//     there is nothing for Dan to grant. Both refusals on his 2026-08-09 run were this, and he had no
//     way to know it without reading the run's event streams.
//   * a refused FETCH or SEARCH means the run's ordinary research routes were blocked, which is a real
//     problem and the case #1835 exists for.
//
// Reported as one count they read identically, which is why he asked what he was supposed to do with
// the line (L11, L80: a message may claim only what its check measured, and one that names a target
// has to give the reader something to do with it).
//
// Pure, so every branch is reachable from a test without a run.
enum WebCallRefusals {

    // What to append after "N web calls refused". Empty when the routes cannot be named, which is the
    // honest answer for a results file written before `deniedByRoute` was decoded, or by a runner that
    // did not record it: the sentence then reads exactly as it did before rather than inventing a route.
    static func routeClause(_ deniedByRoute: [String: Int]?) -> String {
        let named = routesWithRefusals(deniedByRoute)
        guard !named.isEmpty else { return "" }
        return " (\(list(named)))"
    }

    // The routes that actually refused something, most refusals first and alphabetical within a tie, so
    // the order is a property of the data rather than of dictionary iteration (which is unordered, and
    // would make the same run report a different sentence each time it was read).
    //
    // A zero is dropped rather than listed: every route is present in the recorded dictionary whether or
    // not it refused anything, so listing them all would name three routes that were fine alongside the
    // one that was not.
    static func routesWithRefusals(_ deniedByRoute: [String: Int]?) -> [(route: String, count: Int)] {
        guard let deniedByRoute else { return [] }
        return deniedByRoute
            .filter { $0.value > 0 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (route: label(for: $0.key), count: $0.value) }
    }

    // The words for a route, which are what Dan reads rather than the runner's key. An unrecognised key
    // is passed through as itself rather than dropped or renamed: a route added to the runner later is
    // still true, and naming it is better than reporting a refusal with no kind at all (L113 wants no
    // silent default; this one is a passthrough that cannot lose the fact).
    static func label(for key: String) -> String {
        switch key {
        case "browser": return "browser"
        case "fetch": return "page fetch"
        case "search": return "web search"
        case "bash": return "shell"
        default: return key
        }
    }

    // "browser", or "page fetch and browser", or "page fetch, web search and browser". Counts are only
    // spelled out when more than one route refused something, because with a single route the count is
    // already the number at the front of the sentence and repeating it reads as two different figures
    // (#2616's shape: one word must name one unit).
    private static func list(_ routes: [(route: String, count: Int)]) -> String {
        let parts = routes.count == 1
            ? [routes[0].route]
            : routes.map { "\($0.count) \($0.route)" }
        if parts.count == 1 { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}
