import Foundation

// #768 / #802: what Overture proposes to keep watching after Dan hands it a lead.
//
// Dan's spec, refined: handing over a lead means "I care about these people, keep looking at them", so
// the calendar behind it should join the watchlist. But Overture PROPOSES and Dan CONFIRMS, because two
// things it cannot know are exactly the things that matter:
//
//   Whether the page is a recurring NYC calendar or a touring artist's itinerary. An itinerary is mostly
//   not in New York and re-reading it daily pays for nothing. No model call decides this; the sheet says
//   the rule and Dan, who knows, unticks the box.
//
//   Whether the URL he pasted is the org's CALENDAR or just one show's page. A single show's page never
//   changes again, so watching it would be watching nothing, forever, while reporting as healthy. So the
//   URL is shown, editable, rather than guessed at silently.
enum WatchedSourceProposal {
    enum Verdict: Equatable, Sendable {
        // Worth proposing. `orgName` and `listingsURL` are both starting points Dan can correct.
        case propose(orgName: String, listingsURL: String)
        // Its calendar is already on the watchlist. Adding it again would mean fetching, hashing and
        // reading the same page twice every run.
        case alreadyWatching(orgName: String)
        // THEY ASKED DAN TO STOP. Never propose watching them again, and never let a pasted link put
        // them back on the list by a side door. This is the one mistake in the whole feature that cannot
        // be taken back, and a lead is precisely the route by which it would happen: Dan pastes a show
        // he found, forgetting it is the org that wrote to him last spring.
        case refused(orgName: String)
        // Nothing here worth re-checking (we could not read the page, or it carries no listings at all).
        case nothingToWatch
    }

    // `pageURL` is the page we actually READ, which may not be the link Dan pasted: the fetcher follows a
    // ticket link off an unreadable page. Watching the page we could read is the only honest choice, and
    // the sheet tells him which one that is.
    static func verdict(pageURL: String, verdict pageVerdict: PageVerdict,
                        events: [ExtractedEvent], existing: [WatchedSource]) -> Verdict {
        guard let host = URL(string: pageURL)?.host?.lowercased() else { return .nothingToWatch }

        // A page we could not read is not a calendar we can watch. Adding it would mean a source that
        // reports as failing every run forever with nothing Dan can do about it.
        switch pageVerdict {
        case .unreadable, .noDatedContent: return .nothingToWatch
        // `allPast` IS worth watching: a season that has finished is exactly the calendar that will have
        // an autumn on it. That is the whole reason to keep looking rather than pitch once and forget.
        case .upcomingListings, .allPast: break
        }

        // Matched on HOST, not on the exact URL. An org publishes /events, /calendar and /concerts and
        // links between them; three rows for one organization would fetch, hash and read the same
        // calendar three times a run and report it as three sources.
        if let match = existing.first(where: { sameHost($0.listingsURL, host) }) {
            if !match.isActive, match.inactiveReason == .orgRefusal {
                return .refused(orgName: match.orgName)
            }
            if match.isActive { return .alreadyWatching(orgName: match.orgName) }
            // Inactive because DAN removed it as dead. Proposing it again is fine: he can decide the site
            // is worth another try, and that is his call to reverse, unlike a refusal.
        }

        return .propose(orgName: orgName(from: events, host: host), listingsURL: pageURL)
    }

    // The best name we have for whoever this calendar belongs to: the presenter most of its shows name.
    // A guess, shown to Dan in an editable field, never written silently.
    static func orgName(from events: [ExtractedEvent], host: String) -> String {
        let presenters = events.compactMap { event -> String? in
            let name = (event.presenter ?? "").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        let counts = presenters.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        // Sorted by count, then by name, so the same page never proposes a different name run to run
        // purely because a dictionary hashed differently.
        if let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
            return best
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private static func sameHost(_ urlString: String?, _ host: String) -> Bool {
        guard let urlString, let other = URL(string: urlString)?.host?.lowercased() else { return false }
        return other == host || other == "www." + host || host == "www." + other
    }
}
