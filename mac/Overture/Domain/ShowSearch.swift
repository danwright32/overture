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
