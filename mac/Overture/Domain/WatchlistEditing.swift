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

    // #885: the do-not-contact refusal, written ONCE.
    //
    // SourcesView's own header calls this "the one thing in the whole feature that must not be got wrong
    // quietly", and it was written out by hand in three view bodies across two files, in two different
    // wordings, with no test on any of them. The type that RETURNS `.refused(orgName)` is the type that
    // should say what a refusal means.
    static func refusedMessage(orgName: String) -> String {
        "\(orgName) asked not to be contacted, so Overture won't watch their calendar."
    }

    // Resuming a stopped source is a different action, and keeps its own true sentence: "again" is doing
    // real work in it, and would be a lie on a source being added for the first time.
    static func resumeRefusedMessage(orgName: String) -> String {
        "\(orgName) asked not to be contacted, so Overture won't watch them again."
    }

    static func alreadyWatchingMessage(orgName: String) -> String {
        "Already watching \(orgName)'s calendar."
    }

    static let invalidURLMessage = "That doesn't look like a web address."

    static let needsNameMessage = "Give the organization a name so you can recognize it here."
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

    // #845: the way back, in place.
    //
    // Reversing a stop was already possible and graceless: retype the org name and the URL into the add
    // form, which matches the row by host and revives it. Dan could not see that from the button he had
    // just clicked, so a fully reversible action read as a permanent one, and he hesitated over the one
    // action #802's design expects him to take (a failing source NEVER auto-deactivates, precisely so that
    // removing it stays his deliberate choice).
    //
    // This is the same revival, reached by identity rather than by retyping a URL, so an Undo in the
    // banner and a "Watch again" button on the row can both offer it.
    //
    // The refusal is re-checked HERE, not left to the sheet that draws the buttons. The Sources sheet only
    // offers them on a source Dan stopped himself, which is correct and is not the point: an org that
    // asked him to stop must be unable to return to the watchlist BY ANY ROUTE, and a guarantee that lives
    // in a view is a guarantee that lasts until the next view. This is the one mistake here that cannot be
    // taken back, because it ends with somebody being emailed who asked not to be.
    @discardableResult
    static func resumeWatching(_ source: WatchedSource, in context: ModelContext) -> Result {
        if source.isActive { return .alreadyWatching(orgName: source.orgName) }
        guard source.inactiveReason != .orgRefusal else { return .refused(orgName: source.orgName) }

        source.isActive = true
        source.inactiveReason = nil
        try? context.save()
        return .resumed
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

// #885 (guard sweep): the add-a-source button's two states.
extension WatchlistEditing {
    static func addButtonTitle(isOpen: Bool) -> String { isOpen ? "Cancel" : "Watch a calendar" }

    // #970. Deliberately "read", not "check": the app already draws that line (#803). The free daily run
    // CHECKS every source (fetch, hash, notice a change) and spends nothing. Reading is what costs, and
    // it is what produces prospects. This button is the expensive half, for one source.
    static let readOneTitle = "Read this one now"

    static let readOneHelp = "Read this source's listings now, without scouting the rest of the list"
}
