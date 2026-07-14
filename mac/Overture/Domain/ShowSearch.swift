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
}
