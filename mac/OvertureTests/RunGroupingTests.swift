import Testing
import Foundation
@testable import Overture

private func row(_ group: String, _ date: String?, venue: String? = "The Joyce", url: String? = nil,
                 seriesId: String? = nil) -> RunGrouping.RunRow {
    RunGrouping.RunRow(groupName: group, venue: venue, performanceDate: date,
                       sourceListingURL: url ?? (date.map { "u-\($0)" }), seriesId: seriesId)
}

@Suite("Run grouping")
struct RunGroupingTests {
    // #1174: nights that share a feed seriesId are one production and collapse into ONE run with a date
    // SPAN, even when they are weeks apart (past the gap rule) and their per-night titles differ. A
    // VenueTix residency (Green Room 42) is exactly this: same venue, same production id, nights not
    // consecutive. Without the id these would be three separate prospects; here they are one run
    // rendering "opening to closing", so no night is hidden and Dan can pick a later one.
    @Test func collapsesSameSeriesNightsAcrossAnyGapIntoOneRunWithASpan() {
        let out = RunGrouping.group([
            row("An Evening With: Night 1", "2026-11-07", venue: "Green Room 42", seriesId: "gr42-run"),
            row("An Evening With: Night 2", "2026-11-14", venue: "Green Room 42", seriesId: "gr42-run"),
            row("An Evening With: Finale", "2026-11-21", venue: "Green Room 42", seriesId: "gr42-run"),
        ])
        #expect(out.count == 1)                              // ONE prospect, not three
        #expect(out[0].row.performanceDate == "2026-11-07")  // opening night is the primary/sort date
        #expect(out[0].runEndDate == "2026-11-21")           // closing night gives the span
        #expect(out[0].memberIds.count == 3)                 // every night folded in, none dropped
    }

    // A shared seriesId groups the production even when other, unrelated shows sit between its nights in
    // the date order. Adjacency-based clustering would strand a later night in its own run; keying on the
    // id must not.
    @Test func sameSeriesNightsInterleavedWithOtherShowsStillCollapse() {
        let out = RunGrouping.group([
            row("The Residency", "2026-11-07", venue: "Green Room 42", seriesId: "resid"),
            row("Someone Else", "2026-11-10", venue: "Green Room 42", seriesId: "other-show"),
            row("The Residency", "2026-11-21", venue: "Green Room 42", seriesId: "resid"),
        ])
        let residency = try! #require(out.first { $0.row.groupName == "The Residency" })
        #expect(residency.runEndDate == "2026-11-21")
        #expect(residency.memberIds.count == 2)
        #expect(out.count == 2)   // the residency (one run) plus the unrelated show
    }
    @Test func mergesConsecutiveNightsIntoOneRunWithRange() {
        let out = RunGrouping.group([row("Mark Morris", "2026-07-14"), row("Mark Morris", "2026-07-15"), row("Mark Morris", "2026-07-16")])
        #expect(out.count == 1)
        #expect(out[0].row.performanceDate == "2026-07-14")
        #expect(out[0].runEndDate == "2026-07-16")
        #expect(out[0].runSourceURLs.sorted() == ["u-2026-07-14", "u-2026-07-15", "u-2026-07-16"])
        #expect(out[0].partOfRelatedRun == false)
    }

    @Test func chainsAcrossDarkDaysButSplitsOnLargerGap() {
        let out = RunGrouping.group([row("X", "2026-07-01"), row("X", "2026-07-04"), row("X", "2026-07-20")])
        #expect(out.count == 2)
        #expect(out[0].runEndDate == "2026-07-04")
        #expect(out[1].row.performanceDate == "2026-07-20")
        #expect(out[1].runEndDate == nil)
    }

    @Test func flagsSeparateRunsOfSameGroupVenueAsRelated() {
        let out = RunGrouping.group([row("Y", "2026-07-01"), row("Y", "2026-07-20")])
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.partOfRelatedRun })
    }

    @Test func doesNotMergeDifferentVenues() {
        let out = RunGrouping.group([row("Z", "2026-07-01", venue: "Hall A"), row("Z", "2026-07-02", venue: "Hall B")])
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.partOfRelatedRun })
    }

    @Test func singleNightHasNilEndDate() {
        let out = RunGrouping.group([row("Solo", "2026-07-01")])
        #expect(out[0].runEndDate == nil)
        #expect(out[0].runSourceURLs == ["u-2026-07-01"])
    }

    @Test func undatedRowsPassThroughUnmerged() {
        let out = RunGrouping.group([row("U", nil, url: "a"), row("U", nil, url: "b")])
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.runEndDate == nil && !$0.partOfRelatedRun })
    }

    // #369: a ceremony and its differently-titled sub-event (a "Guest Artist:" night) at the
    // same venue on an adjacent date must merge into one run, using GroupNameMatch's existing
    // name-similarity check instead of exact title equality. The shorter title (the general
    // ceremony name, not the specific sub-event name) becomes the run's displayed representative.
    @Test func ceremonySubEventWithGuestArtistTitleMergesWithParentCeremony() {
        let out = RunGrouping.group([
            row("Golden Classical Music Awards Ceremony", "2026-07-08", venue: "Weill Recital Hall"),
            row("Golden Classical Music Awards Ceremony Guest Artist: Aurelia Faidley-Solars, Cello",
                "2026-07-09", venue: "Weill Recital Hall"),
        ])
        #expect(out.count == 1)
        #expect(out[0].row.groupName == "Golden Classical Music Awards Ceremony")
        #expect(out[0].runEndDate == "2026-07-09")
        #expect(out[0].partOfRelatedRun == false)
        #expect(out[0].runSourceURLs.sorted() == ["u-2026-07-08", "u-2026-07-09"])
    }

    // #369: the shortest-title tiebreak must win regardless of which night is chronologically
    // first. Same pair as above with the dates swapped, proving the representative isn't just
    // "whichever row sorts first" coinciding with the shorter title by chance.
    @Test func shortestTitleWinsAsRepresentativeEvenWhenItIsTheLaterNight() {
        let out = RunGrouping.group([
            row("Golden Classical Music Awards Ceremony Guest Artist: Aurelia Faidley-Solars, Cello",
                "2026-07-08", venue: "Weill Recital Hall"),
            row("Golden Classical Music Awards Ceremony", "2026-07-09", venue: "Weill Recital Hall"),
        ])
        #expect(out.count == 1)
        #expect(out[0].row.groupName == "Golden Classical Music Awards Ceremony")
        #expect(out[0].runEndDate == "2026-07-09")
    }

    // #369: a genuinely different act sharing both a venue and a long common title prefix must
    // NOT merge. GroupNameMatch.isConfident requires the shorter name's full token sequence to
    // appear as a contiguous run inside the longer one; these two diverge partway through
    // ("The Bright Sparks" vs "The Dizzy Gillespie All Stars"), so it correctly returns false.
    // Guards against the grouping fix becoming too aggressive.
    @Test func differentActsAtSameVenueStayUnmergedDespiteSharedPrefix() {
        let out = RunGrouping.group([
            row("Jazz at Lincoln Center Presents The Bright Sparks", "2026-07-01", venue: "Rose Theater"),
            row("Jazz at Lincoln Center Presents The Dizzy Gillespie All Stars", "2026-07-03", venue: "Rose Theater"),
        ])
        #expect(out.count == 2)
        #expect(out.allSatisfy { !$0.partOfRelatedRun })
    }
}
