import Foundation

// #1432: finding ONE source by name, on a watchlist that passed 38 in #359's backfill and only grows.
//
// A domain rule rather than a filter written inline in the sheet, for the reason #863 established: logic
// inside a SwiftUI view is logic the suite cannot run, and this decides what Dan can and cannot find.
//
// Deliberately forgiving. Dan is typing from memory on a US keyboard against names that are titlecase
// and sometimes accented, and he thinks of an organization as a couple of words in no fixed order. A
// strict prefix or substring match would send him back to scrolling, which is the thing the field exists
// to stop. It matches the NAME only (his call, 2026-07-23): the address is not how he thinks of a source,
// and matching it would drag in every organization sharing a ticketing host.
enum SourceSearch {
    // The one rule about this field Dan cannot discover by using it: it reads the NAME. A search typed
    // against an address otherwise comes back empty with nothing on screen explaining why.
    static let fieldPlaceholder = "Search by name"

    // Said out loud, because an empty sheet on its own reads as the sources having gone, and on this
    // sheet that is an alarming thing to appear to have happened. "Name" repeats the placeholder on
    // purpose: the placeholder is invisible by the time Dan is looking at an empty result, and typing an
    // address is the likeliest reason he got one.
    static let noMatchesLine = "No source matches that name."

    // The X draws as an icon with nothing written beside it, so this is its only spoken name.
    static let clearButtonLabel = "Clear the search"

    // Whether the sheet is filtering at all. Whitespace alone is NOT a search: clearing the field can
    // leave a stray space, and a sheet still filtering after Dan cleared it reads as sources vanishing.
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Every word Dan typed has to appear somewhere in the name, in any order. Any-word matching would
    // make a longer query broader than a short one, so typing more would return more.
    static func matches(name: String, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }   // an empty field matches everything, and shows all
        return words.allSatisfy { word in
            name.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // An empty query returns the list UNCHANGED, and a query that matches nothing returns nothing. The
    // second half matters: falling back to the full list on no match would read as the search having
    // failed to apply, so the sheet needs the empty result to be real in order to say so.
    static func filter(_ sources: [WatchedSource], query: String) -> [WatchedSource] {
        guard isSearching(query) else { return sources }
        return sources.filter { matches(name: $0.orgName, query: query) }
    }
}
