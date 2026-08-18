import Testing
import Foundation

// Built is not wired (L3). The rule in `RowSourceListingLinkTests` is a sentence the app never says unless
// the stages Dan works an OPEN PITCH on actually draw it.
//
// Its own file rather than a second suite beside that rule, which was originally a workaround: #629's
// meta-guard reads a file that calls `SourceGuard.functionBody` for the function names it references and
// checks each one still exists, and it collected those from anything array-shaped after an equals sign, so
// `#expect(table == ["hall": "https://example-hall.example/whats-on"])` in the rule's own tests read as a
// list of function names and reported that "hall" was a function that had gone missing. #2953 fixed that
// (a dictionary is no longer read as a list of names, and the sweep reads code rather than comments), so
// the example above can be written out here, where before it made the guard fail on the sentence
// explaining why it failed. The split stays because these are the wiring tests, not the rule's.
@Suite("The stages that work an open pitch actually draw the link (#2816)")
struct RowSourceListingLinkWiringTests {

    private func leadingColumn(ofFunction name: String, in path: String, opening: String) throws -> String {
        let source = SourceGuardHelper.source(path)
        #expect(!source.isEmpty)
        let body = try String(SourceGuard.functionBody(named: name, in: source))
        return try #require(SourceGuardHelper.between(opening, and: "Spacer(minLength: OVSpacing.sm)",
                                                      in: body),
                            "\(name)'s leading column was not found where the guard expects it")
    }

    // The reached-out row: the surface the issue was filed from.
    @Test func theReachedOutRowDrawsTheLink() throws {
        let leading = try leadingColumn(ofFunction: "reachedOutRow", in: "Overture/UI/QueueView.swift",
                                        opening: "VStack(alignment: .leading, spacing: 3) {")
        #expect(leading.contains("RowSourceLink("),
                "the reached-out row no longer offers a way back to the show's own page (#2816)")
    }

    // The one rendering the three surfaces share. Asked HERE rather than of each row, because that is
    // where it lives: a copy per row is how the colour override comes to be on two of them and missing
    // on the third.
    @Test func theSharedLinkAsksTheModelAndOverridesTheLinkColour() {
        let source = SourceGuardHelper.source("Overture/UI/RowSourceLink.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("QueueModel.rowListingLink("),
                "the shared link no longer asks the model what it is linking to, or what to call it")
        // #358: .tint does not recolor a Link's own text on macOS, so without its own override the link
        // ships in bright system blue against the forest and gold palette.
        #expect(source.contains("OVColor.forestText"),
                "the shared link has no colour override, so it draws in system blue (#358)")
    }

    // Decision 2 of #2816's three open questions: the link belongs with the SHOW's own information (the
    // group name and the night it is on), not with the conversation. The audience, the channel line and
    // the proposed-conversation block are all about the conversation, and they follow it.
    @Test func theLinkSitsWithTheShowRatherThanWithTheConversation() throws {
        let leading = try leadingColumn(ofFunction: "reachedOutRow", in: "Overture/UI/QueueView.swift",
                                        opening: "VStack(alignment: .leading, spacing: 3) {")
        let date = try #require(leading.range(of: "ReachedOutRowChrome.showDateLine"))
        let link = try #require(leading.range(of: "RowSourceLink("))
        let conversation = try #require(leading.range(of: "ReplyIdentity.rowAudience"))
        #expect(date.lowerBound < link.lowerBound,
                "the link draws above the show's own date line, splitting the show's own facts")
        #expect(link.lowerBound < conversation.lowerBound,
                "the link draws below the conversation, which is not what it is about (#2816 decision 2)")
    }

    // Both of the Follow-ups rows, named where #629's meta-guard can read them: it sweeps a test file's
    // array literals for the function names a `named:` loop variable stands for, and a file it cannot
    // read a name out of is one it reports as unreadable rather than as passing.
    private static let followUpRows: [(function: String, opening: String)] = [
        ("row", "VStack(alignment: .leading, spacing: 2) {"),
        ("postEventRow", "VStack(alignment: .leading, spacing: 3) {"),
    ]

    // Decision 3: Follow-ups is the other surface where an open pitch is worked, and BOTH of its rows are
    // covered rather than only the one the issue named (the class, not the instance).
    @Test func bothFollowUpRowsDrawTheLink() throws {
        for (name, opening) in Self.followUpRows {
            let leading = try leadingColumn(ofFunction: name, in: "Overture/UI/FollowUpsView.swift",
                                            opening: opening)
            #expect(leading.contains("RowSourceLink("),
                    "FollowUpsView.\(name) offers no way back to the show's own page (#2816)")
        }
    }

    // The label is only as good as the table it is handed, and an EMPTY table makes every row read
    // "Source listing", which is the same silent wrongness #1825 fixed pointing the other way. Both
    // surfaces have to hold a live watchlist query and resolve their rows through it.
    @Test func bothSurfacesResolveTheirLinksAgainstTheLiveWatchlist() {
        for path in ["Overture/UI/QueueView.swift", "Overture/UI/FollowUpsView.swift"] {
            let source = SourceGuardHelper.source(path)
            #expect(source.contains("@Query private var watchedSources: [WatchedSource]"),
                    "\(path) has no live watchlist to resolve a link's label against")
            #expect(source.contains("QueueModel.sourceCalendarIndex(watchedSources)"),
                    "\(path) never builds the calendar table, so every link would read as an event page")
        }
    }
}
