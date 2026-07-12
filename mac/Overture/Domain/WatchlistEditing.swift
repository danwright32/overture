import Foundation
import SwiftData

// #802: adding and removing a watched calendar by hand.
//
// Until this existed, a calendar could only join the watchlist by pasting a lead, and if Dan unticked
// "keep watching" on that sheet he could never change his mind: re-pasting the same link is refused as
// already handed over, and the Sources sheet was read-only. A dead end with no way out of it.
//
// The refusal rule is enforced HERE, not in the sheet, for the same reason it is enforced in
// LeadIntakeModel.confirm rather than in its checkbox: an org that asked Dan to stop must not be able to
// get back onto the watchlist by any route, including one he types in himself, and a guarantee that
// lives in a view is a guarantee that lasts until the next view.
@MainActor
enum WatchlistEditing {
    enum Result: Equatable, Sendable {
        case added
        case resumed                       // a source Dan had stopped, revived with its history intact
        case alreadyWatching(orgName: String)
        case refused(orgName: String)      // they asked him to stop. Not by this route either.
        case invalidURL
        case needsName
    }

    @discardableResult
    static func add(orgName: String, listingsURL: String, into context: ModelContext) -> Result {
        let name = orgName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = listingsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .needsName }
        guard let host = URL(string: url)?.host, !host.isEmpty,
              URL(string: url)?.scheme?.hasPrefix("http") == true else { return .invalidURL }

        let existing = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []

        // Matched on host, so an org that publishes /events, /calendar and /concerts cannot end up on the
        // list three times, fetching, hashing and reading the same calendar three times every run.
        if let match = existing.first(where: { sameHost($0.listingsURL, as: url) }) {
            if !match.isActive, match.inactiveReason == .orgRefusal {
                return .refused(orgName: match.orgName)
            }
            if match.isActive { return .alreadyWatching(orgName: match.orgName) }

            // Stopped by Dan, and he has changed his mind. Revive the EXISTING row rather than inserting
            // a second one: it carries the feed history it earned, and its id is stamped on every
            // prospect it ever surfaced.
            match.isActive = true
            match.inactiveReason = nil
            match.listingsURL = url
            try? context.save()
            return .resumed
        }

        context.insert(WatchedSource(sourceId: WatchedSource.newSourceId(for: url), orgName: name,
                                     listingsURL: url, kind: .html))
        try? context.save()
        return .added
    }

    // Dan stops watching a source. Recorded as HIS decision, never as a refusal: one is a choice he can
    // revisit and the other is a line he must not cross, and a Sources sheet that showed them the same
    // way would eventually get somebody emailed who asked not to be.
    //
    // The row is kept, not deleted. Deleting it would take its feed history with it, and its id is
    // stamped on every prospect it ever surfaced.
    static func stopWatching(_ source: WatchedSource, in context: ModelContext) {
        source.isActive = false
        source.inactiveReason = .removedByDan
        try? context.save()
    }

    private static func sameHost(_ urlString: String?, as other: String) -> Bool {
        func host(_ s: String?) -> String? {
            guard let s, let h = URL(string: s)?.host?.lowercased() else { return nil }
            return h.replacingOccurrences(of: "www.", with: "")
        }
        guard let a = host(urlString), let b = host(other) else { return false }
        return a == b
    }
}
