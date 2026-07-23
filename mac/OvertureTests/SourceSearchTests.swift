import Testing
import Foundation
@testable import Overture

// #1432: finding ONE source by name on a watchlist that has grown past 38 and keeps growing.
//
// The matching is a domain rule with its own tests rather than a filter written inline in the sheet,
// for the reason #863 established: logic inside a SwiftUI view is logic the suite cannot run. The
// forgiving parts below (case, accents, words in any order) are the whole point: a search that only
// matches the exact prefix Dan typed sends him back to scrolling, which is the thing he asked to stop
// doing.
@Suite("Finding a source by name (#1432)")
struct SourceSearchTests {
    // MARK: - When the sheet is searching at all

    // An empty field is not a search, and it must show the full grouped list. The distinction has to be
    // a tested fact because it is what decides whether the sheet renders its normal sections or a
    // filtered set, and "empty query matches nothing" would blank the whole sheet.
    @Test func anEmptyQueryIsNotASearch() {
        #expect(SourceSearch.isSearching("") == false)
    }

    // Whitespace alone is the case a plain isEmpty check gets wrong: Dan clearing the field can leave a
    // stray space behind, and a sheet that stays in the filtered state after he cleared it reads as
    // sources having vanished.
    @Test func whitespaceAloneIsNotASearch() {
        #expect(SourceSearch.isSearching("   ") == false)
    }

    @Test func anyRealTextIsASearch() {
        #expect(SourceSearch.isSearching("carnegie"))
    }

    // MARK: - What matches a name

    @Test func anEmptyQueryMatchesEverySource() {
        #expect(SourceSearch.matches(name: "Carnegie Hall", query: ""))
    }

    // Dan types lowercase; the names are titlecase. Requiring him to match the case would make the field
    // useless for its one job.
    @Test func matchingIgnoresCase() {
        #expect(SourceSearch.matches(name: "Carnegie Hall", query: "carnegie"))
        #expect(SourceSearch.matches(name: "carnegie hall", query: "CARNEGIE"))
    }

    // Real names on this watchlist carry accents, and Dan is typing on a US keyboard. If "theatre" does
    // not find "Théâtre", the accented sources are the exact ones he can never search for.
    @Test func matchingIgnoresAccents() {
        #expect(SourceSearch.matches(name: "Théâtre du Châtelet", query: "theatre"))
        #expect(SourceSearch.matches(name: "Theatre du Chatelet", query: "théâtre"))
    }

    @Test func matchingFindsAWordInTheMiddleOfAName() {
        #expect(SourceSearch.matches(name: "The Metropolitan Opera", query: "opera"))
    }

    // THE case a plain substring check gets wrong. Dan thinks of the organization as "opera" plus a
    // place, and types them in whichever order comes to mind. "phil opera" is not a substring of
    // "Opera Philadelphia", so a contains-check returns nothing and the source he can see on the list
    // reads as missing.
    @Test func everyWordMatchesInAnyOrder() {
        #expect(SourceSearch.matches(name: "Opera Philadelphia", query: "phil opera"))
        #expect(SourceSearch.matches(name: "Opera Philadelphia", query: "opera phil"))
    }

    // The other half of that rule: EVERY word has to land. Matching on any one word would make a
    // two-word query broader than a one-word query, so typing more would return more.
    @Test func aQueryWhoseWordsDoNotAllLandDoesNotMatch() {
        #expect(SourceSearch.matches(name: "Opera Philadelphia", query: "opera boston") == false)
    }

    @Test func anUnrelatedQueryDoesNotMatch() {
        #expect(SourceSearch.matches(name: "Carnegie Hall", query: "bargemusic") == false)
    }

    // MARK: - What the sheet says

    // The placeholder carries the one rule Dan cannot otherwise discover: this searches the NAME. Without
    // it, a search typed against an address comes back empty with nothing explaining why.
    @Test func thePlaceholderSaysItSearchesTheName() {
        #expect(SourceSearch.fieldPlaceholder.localizedCaseInsensitiveContains("name"))
    }

    // A search that matches nothing must SAY so. An empty sheet on its own reads as the sources having
    // gone, which on this particular sheet is an alarming thing to appear to have happened.
    @Test func aSearchThatFindsNothingSaysSoRatherThanShowingABlankSheet() {
        #expect(SourceSearch.noMatchesLine.isEmpty == false)
        #expect(SourceSearch.noMatchesLine.localizedCaseInsensitiveContains("name"))
    }

    // The X that clears the field draws as an icon with no text beside it, so its only name is the one
    // VoiceOver reads.
    @Test func theClearButtonHasASpokenName() {
        #expect(SourceSearch.clearButtonLabel.isEmpty == false)
    }

    // MARK: - Filtering the list

    // Dan's locked scope: the NAME only, never the address. A source whose URL contains the query but
    // whose name does not must not surface, or searching "opera" would drag in every organization that
    // happens to sit on a shared ticketing host.
    @Test func filteringMatchesTheNameAndNeverTheURL() {
        let sources = [
            WatchedSource(sourceId: "a", orgName: "Bargemusic",
                          listingsURL: "https://tickets.operahost.com/bargemusic", kind: .html),
            WatchedSource(sourceId: "b", orgName: "Opera Saratoga",
                          listingsURL: "https://operasaratoga.org/season", kind: .html),
        ]

        let found = SourceSearch.filter(sources, query: "opera")

        #expect(found.map(\.sourceId) == ["b"])
    }

    @Test func anEmptyQueryReturnsEverySourceUnchanged() {
        let sources = [
            WatchedSource(sourceId: "a", orgName: "Carnegie Hall", kind: .algolia),
            WatchedSource(sourceId: "b", orgName: "Bargemusic", kind: .html),
        ]

        #expect(SourceSearch.filter(sources, query: "  ").map(\.sourceId) == ["a", "b"])
    }

    // A query that finds nothing returns nothing, rather than falling back to the full list. The sheet
    // needs the empty result to be real so it can say "no source matches", and a filter that silently
    // showed everything again would read as the search having failed to apply.
    @Test func aQueryThatMatchesNothingReturnsNothing() {
        let sources = [WatchedSource(sourceId: "a", orgName: "Carnegie Hall", kind: .algolia)]

        #expect(SourceSearch.filter(sources, query: "bargemusic").isEmpty)
    }

    // #1432 (Dan, 2026-07-23): search covers EVERY section, including the organizations that asked him
    // to stop. They stay findable, and the sheet keeps its section headings while searching precisely so
    // that a refusal surfaced by a search is still labelled as one rather than sitting namelessly beside
    // a source he actively watches (the #800 mistake that cannot be taken back).
    @Test func searchReachesSourcesThatAskedDanToStop() {
        let stopped = WatchedSource(sourceId: "stopped", orgName: "On Site Opera", kind: .html)
        stopped.isActive = false
        stopped.inactiveReason = .orgRefusal

        let found = SourceSearch.filter([stopped], query: "on site")

        #expect(found.map(\.sourceId) == ["stopped"])
        #expect(SourceGrade(found[0]) == .stoppedAtTheirRequest)
    }
}
