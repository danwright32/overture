import Testing
import Foundation
@testable import Overture

private func row(_ group: String, _ date: String?, venue: String? = "The Joyce", url: String? = nil) -> RunGrouping.RunRow {
    RunGrouping.RunRow(groupName: group, venue: venue, performanceDate: date, sourceListingURL: url ?? (date.map { "u-\($0)" }))
}

@Suite("Run grouping")
struct RunGroupingTests {
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
}
