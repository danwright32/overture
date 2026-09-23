import Testing
import Foundation

// #4030 (and #3316, closed in its favour): one card for a group of rows that are one show.
//
// #3282 gave every member of a group a sentence saying the store holds the show more than once, which
// was the right first move and is the wrong end state: at the real count it is the wall of identical
// text it was meant to replace (L579). The archive holds twelve rows of The Infinite Wrench, each
// carrying "This show is stored 12 times."
//
// #3316 asked for the opposite fix, running the merge after every scout so the store tidies itself
// sooner. That was closed in favour of this, because the merge DELETES rows and leans on the launch
// backup, and giving it a fresh backup per scout would evict the launch history it rotates against
// (L191). Collapsing at read time deletes nothing and a wrong join costs a re-render.
//
// DAN'S DECISIONS, 2026-09-20 (this session, in chat), because none of these follows from the rule:
//   - the card is fronted by a row the feed still lists, earliest opening night among those;
//   - an action on the card applies to EVERY row in the group, so a duplicate cannot come back
//     untriaged later, which is the complaint that started this milestone;
//   - no split control yet. He chose to watch for a wrong grouping rather than build the remedy up
//     front, and that is safe in a way worth writing down: a dismissal is reversible per row from the
//     Archive through `DismissedProspects.restore`, so a wrong group-wide dismiss is recoverable.
@Suite("One card for a group of rows that are one show (#4030)")
struct CollapsedShowCardTests {

    // A row's nights INTERSECT its group's, because that is what `ShowLink` joins on. A first draft
    // gave each row one distinct night and nothing grouped at all: two copies of one run that share no
    // night are not the same show by this rule, correctly, so a fixture built that way tests nothing
    // (L159). Each row here is a weekly run whose nights overlap its neighbours', which is the live
    // shape: The Infinite Wrench plays every Friday and each stored copy carries a window of them.
    private func row(_ id: String, night: String, inFeed: Bool = true,
                     title: String = "The Infinite Wrench",
                     venue: String = "Asylum NYC") -> ShowLink.Row {
        let nights = [night, "2026-10-16", "2026-10-23"]
        return ShowLink.Row(id: id, groupName: title, venue: venue, performanceDate: night,
                            runNights: nights, isStillInFeed: inFeed)
    }

    // THE RULE. A row the feed still lists fronts the card, even when an older row is not listed.
    @Test func theFrontIsARowTheFeedStillLists() {
        let gone = row("gone", night: "2026-10-02", inFeed: false)
        let live = row("live", night: "2026-10-09", inFeed: true)

        let collapsed = ShowLink.collapse([gone, live])
        #expect(collapsed.fronts.keys.sorted() == ["live"],
                "a row the source still lists fronts the card over one it has stopped listing")
        #expect(collapsed.hidden == ["gone"])
        #expect(collapsed.fronts["live"]?.sorted() == ["gone", "live"],
                "the front names every member, itself included, so an action can reach them all")
    }

    // Among the listed rows, the earliest night. Dan meets the run at its opening.
    @Test func theEarliestNightFrontsAmongListedRows() {
        let later = row("later", night: "2026-10-09")
        let earlier = row("earlier", night: "2026-10-02")

        #expect(ShowLink.collapse([later, earlier]).fronts.keys.sorted() == ["earlier"])
    }

    // When NOTHING in the group is still listed, the group still collapses. A card that vanished
    // because every copy went quiet would be worse than one fronted by a retired row, and the archive's
    // twelve-row group is exactly this case.
    @Test func aGroupWhereNothingIsListedStillCollapses() {
        let a = row("a", night: "2026-10-02", inFeed: false)
        let b = row("b", night: "2026-10-09", inFeed: false)

        let collapsed = ShowLink.collapse([a, b])
        #expect(collapsed.fronts.keys.sorted() == ["a"], "the earliest night fronts when none is listed")
        #expect(collapsed.hidden == ["b"])
    }

    // A row that stands alone is not a group and is never hidden. The commonest case by far, and the
    // one a collapse must not touch.
    @Test func aRowThatStandsAloneIsUntouched() {
        let only = row("only", night: "2026-10-02")
        // A different show entirely: a different folded title, so the night overlap cannot join them.
        let elsewhere = row("elsewhere", night: "2026-10-02", title: "Gross Prophets")

        let collapsed = ShowLink.collapse([only, elsewhere])
        #expect(collapsed.fronts.isEmpty, "nothing was grouped, so nothing fronts anything")
        #expect(collapsed.hidden.isEmpty)
    }

    // DETERMINISM, which is not decoration here: the hidden set decides what Dan can see, so a rule
    // that broke ties by fetch order would show him a different card on different launches for the same
    // store (L343, L419).
    @Test func twoListedRowsOnOneNightBreakTheTieTheSameWayEveryTime() {
        let b = row("b", night: "2026-10-02")
        let a = row("a", night: "2026-10-02")

        #expect(ShowLink.collapse([b, a]).fronts.keys.sorted() == ["a"])
        #expect(ShowLink.collapse([a, b]).fronts.keys.sorted() == ["a"],
                "the answer may not depend on the order the rows arrived in")
    }

    // The collapse is built ON the grouping and may never invent one: whatever `group` refuses to join
    // stays apart here too. Asserted against `group` itself rather than against a literal, so the two
    // cannot drift (L58).
    @Test func theCollapseJoinsExactlyWhatTheGroupingJoins() {
        let rows = [row("a", night: "2026-10-02"), row("b", night: "2026-10-02"),
                    row("other", night: "2026-10-02", title: "Something Else Entirely")]
        let grouped = ShowLink.group(rows)
        let collapsed = ShowLink.collapse(rows)

        #expect(Set(collapsed.fronts.values.flatMap { $0 }) == Set(grouped.keys),
                "every row the grouping put in a group is a member of exactly one collapsed card")
        #expect(!collapsed.hidden.contains("other"))
    }
}
