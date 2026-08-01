import Foundation

// Matches a show against a free text query, shared by the global search bar and Archive's
// own search field: org/act name, venue, and every recipient's name/email, so Dan can find a show
// whether he remembers who he pitched, where it was, or who replied. Case insensitive substring
// match; an empty (or all whitespace) query matches everything.
enum ShowSearch {
    static func matches(_ item: QueueItem, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if contains(item.groupName, trimmed) { return true }
        if let venue = item.venue, contains(venue, trimmed) { return true }
        for contact in item.contacts {
            if let name = contact.name, contains(name, trimmed) { return true }
            if let email = contact.email, contains(email, trimmed) { return true }
        }
        return false
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

// #1926: searching, with the list of shows arriving as something to build rather than something built.
//
// The queue's bar searches the shows a stage will render, and working that out is a
// StageNavigation.stagedKeys sweep of every prospect plus a map over all of them. As a plain argument at
// the call site it ran on every render pass, including every pass where the box was empty and nobody was
// searching, because an argument evaluates before the function it is handed to can decide it is not
// needed (#1916, one level up). Taken as an @autoclosure, the blank-query guard below returns first and
// the sweep never happens.
//
// The matching, the ordering and the cap live here rather than in the field's body for the ordinary
// reason: a rule stated in a SwiftUI body is one no test can reach.
extension ShowSearch {
    // How many results the dropdown will show. It is a UI cap, so it is stated once, here, next to the
    // sort that decides WHICH ones survive it.
    static let resultLimit = 8

    static func results(in items: @autoclosure () -> [QueueItem], query: String,
                        limit: Int = resultLimit) -> [QueueItem] {
        guard isSearching(query) else { return [] }
        return Array(
            items()
                .filter { matches($0, query: query) }
                // Soonest last: the nearest dates are the ones Dan can still act on. An undated show
                // sorts to the end rather than out of the list, since losing it entirely is the worse
                // failure and the two orderings are otherwise arbitrary.
                .sorted { ($0.performanceDate ?? "") > ($1.performanceDate ?? "") }
                .prefix(limit)
        )
    }

    // #1580's "the show is in Archive" count. Counted, never listed, and never built on a blank query for
    // the same reason as above: with nothing typed there is nothing for it to say.
    static func matchCount(in items: @autoclosure () -> [QueueItem], query: String) -> Int {
        guard isSearching(query) else { return 0 }
        return items().filter { matches($0, query: query) }.count
    }

    // One definition of "Dan is searching", shared by both of the above and by the field that decides
    // whether to open its dropdown, so a blank-but-for-spaces query cannot count as a search in one place
    // and not in another.
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// #885: the empty-result line, out of ShowSearchField's body. It quotes back what Dan typed, which is
// what makes it useful (a typo is visible in it), and that quoting was being done in a view.
extension ShowSearch {
    static func noMatchesNote(query: String) -> String { "No matches for \"\(query)\"" }

    // #1580: what an empty result MEANS, now that the global bar searches only the shows a stage will
    // render. "No matches" was true of the whole store before; against the narrowed scope it is usually
    // false, because the show is sitting in Archive. Saying which of the two happened is the difference
    // between a dead end and a next step, so the second case carries the jump.
    //
    // A value, not two strings composed in the view, so the wording and the "which case is this" rule
    // can be read by a test. Archive's own field passes no count and gets the plain line.
    struct EmptyState: Equatable {
        let note: String
        let archiveMatches: Int

        var offersArchive: Bool { archiveMatches > 0 }
        // The count lives here and nowhere else. Stating it in the sentence too would be the same
        // number twice on one small popover (#843).
        var archiveAction: String { "Look in Archive (\(archiveMatches))" }
    }

    static func emptyState(query: String, archiveMatches: Int) -> EmptyState {
        guard archiveMatches > 0 else {
            return EmptyState(note: noMatchesNote(query: query), archiveMatches: 0)
        }
        return EmptyState(note: "Nothing in the queue matches \"\(query)\"", archiveMatches: archiveMatches)
    }
}
