import Testing
import Foundation

private let tokenHost = "https://thegreenroom42.venuetix.com/showdetails"

private func row(_ group: String, _ date: String, venue: String = "The Green Room 42",
                 token: String? = nil) -> RunGrouping.RunRow {
    RunGrouping.RunRow(groupName: group, venue: venue, performanceDate: date,
                       sourceListingURL: token.map { "\(tokenHost)/\($0)/\(date)" } ?? "u-\(date)",
                       seriesId: nil)
}

// #4051: the grouper clusters authoritatively by `seriesId` with no gap window, precisely because the
// nights of one production can be weeks apart. Everything without one falls to the gap walk, which joins
// two nights only when they are at most `sameShowGapDays` (56) apart.
//
// The venuetix production token is the SAME KIND of feed production id, and it is exactly as
// authoritative: `ScoutService.matchByProductionToken` already re-keys a stored row on it. But it lives
// in the listing URL and never reaches `seriesId`, so the grouper cannot see it. `RunGrouping` carries
// `sourceListingURL` through to `runSourceURLs` and never reads it for clustering.
//
// PREMISE RE-CHECKED 2026-09-21 against the code and the store, per #4096. All of the above holds. One
// clause of the issue is stale and harmless: it says `ShowLink.ProductionToken` is "currently private"
// and being made reusable, which #4029 has since done, so the shared reader this needs already exists.
// Re-measured the same day: `discardedTokens=0` over 1,273 rows, so the discard below is inert today and
// is here to refuse the failure on the day a venue starts stamping one token across its season.
@Suite("The grouper clusters by the venuetix production token too (#4051)")
struct RunGroupingProductionTokenTests {

    // THE CASE, and it is the live one. `Operation Mincemeat: Mission Recast` at The Green Room 42, two
    // nights 70 days apart sharing one token. Past the 56 day window, so the gap walk refuses it, and
    // with no `seriesId` the authoritative path never sees it either.
    //
    // It survived in the real store only because the two nights arrived in DIFFERENT sweeps, where the
    // ingest match chain can reach it. One sweep carrying both produces two rows and nothing later joins
    // them, which is the case this closes.
    @Test func twoNightsOfOneProductionJoinAcrossAnyGap() {
        let out = RunGrouping.group([
            row("Operation Mincemeat: Mission Recast", "2026-08-17", token: "GWKuL2pmNJBPIkIkHB0h"),
            row("Operation Mincemeat: Mission Recast", "2026-10-26", token: "GWKuL2pmNJBPIkIkHB0h"),
        ])

        #expect(out.count == 1,
                Comment(rawValue: "70 days apart under one production token is one run, got \(out.count)"))
        #expect(out.first?.memberDates == ["2026-08-17", "2026-10-26"])
        #expect(out.first?.runEndDate == "2026-10-26")
    }

    // The token is authoritative about the PRODUCTION, never about the venue. Two rooms are two runs
    // whatever the id says, which is the same rule the venue bucket already imposes on `seriesId`.
    @Test func onetokenAcrossTwoVenuesIsStillTwoRuns() {
        let out = RunGrouping.group([
            row("A Show", "2026-08-17", venue: "The Green Room 42", token: "sharedToken"),
            row("A Show", "2026-10-26", venue: "Asylum NYC", token: "sharedToken"),
        ])

        #expect(out.count == 2, "a token cannot join two rooms, whatever it claims")
    }

    // THE DISCARD, which is what makes this safe to apply with no human in the loop. A venue stamping one
    // token across its whole season would otherwise fuse the season into a single card, and the rule is
    // the one `ShowLink.poisonedTokens` already owns rather than a second copy of the judgement (L370).
    @Test func atokenUnderTwoTitlesAtOneVenueJoinsNothing() {
        let out = RunGrouping.group([
            row("First Show", "2026-08-17", token: "seasonToken"),
            row("First Show", "2026-10-26", token: "seasonToken"),
            row("Second Show", "2026-08-20", token: "seasonToken"),
        ])

        #expect(out.count == 3,
                Comment(rawValue: "a season stamp fused rows it must not, leaving \(out.count) runs"))
    }

    // A tixr slug is the title slugified plus a per performance integer, so it is never identity
    // evidence. `ProductionToken` allows only measured hosts, and this asserts the grouper inherits that
    // rather than admitting anything URL shaped.
    @Test func atixrSlugIsNeverAProductionToken() {
        let out = RunGrouping.group([
            RunGrouping.RunRow(groupName: "Open Mic", venue: "Asylum NYC",
                               performanceDate: "2026-08-17",
                               sourceListingURL: "https://www.tixr.com/groups/asylum/events/open-mic-8814",
                               seriesId: nil),
            RunGrouping.RunRow(groupName: "Open Mic", venue: "Asylum NYC",
                               performanceDate: "2026-10-26",
                               sourceListingURL: "https://www.tixr.com/groups/asylum/events/open-mic-9102",
                               seriesId: nil),
        ])

        #expect(out.count == 2, "a tixr slug is not a production id and must not join across the gap")
    }

    // THE GUARD FOR THE MISTAKE THIS CHANGE FIRST MADE, and the first version of this test did not
    // catch it, which is why the case is the one it is.
    //
    // The discard asks whether one token appears under more than one folded TITLE. The first version
    // folded with `GroupNameMatch.tokens(...).joined(" ")` while the ingest arm asks the identical
    // question through `ShowLink.foldedTitle`. The two are not interchangeable: `GroupNameMatch.normalize`
    // STRIPS THE SUBTITLE by default (that is what its `strippingSubtitle: false` variant exists to opt
    // out of), and `TitleNormalization.normalizeForKey` does not.
    //
    // So two DIFFERENT productions of one company, distinguished only by their subtitles, read as one
    // title under the wrong fold. A season token they share is then not poisoned, and the grouper fuses
    // them into a single run across any gap. That is the failure the discard exists to prevent, arriving
    // through the discard itself.
    //
    // A first attempt used "Nihao Broadway" against "Nihao Broadway!" and SURVIVED the mutation, because
    // both folds agree about a trailing mark. A guard that cannot go red reads exactly like one that
    // works (L1).
    @Test func thediscardUsesTheSameFoldTheIngestArmUses() {
        let out = RunGrouping.group([
            row("Operation Mincemeat: Mission Recast", "2026-08-17", token: "seasonToken"),
            row("Operation Mincemeat: Second Coming", "2026-10-26", token: "seasonToken"),
        ])

        #expect(out.count == 2,
                Comment(rawValue: "two productions sharing a season token were fused into \(out.count) "
                        + "run: the discard folded their titles a way that drops what distinguishes them"))
    }

    // A real `seriesId` still wins, so this does not disturb the path that already worked. Both rows
    // carry a token AND an id; the answer must be the same either way, which it is because both are
    // authoritative about the same thing.
    @Test func arealSeriesIdStillGroupsAsItAlwaysDid() {
        let out = RunGrouping.group([
            RunGrouping.RunRow(groupName: "A Residency", venue: "The Green Room 42",
                               performanceDate: "2026-08-17",
                               sourceListingURL: "\(tokenHost)/tok/1", seriesId: "gr42-run"),
            RunGrouping.RunRow(groupName: "A Residency", venue: "The Green Room 42",
                               performanceDate: "2026-10-26",
                               sourceListingURL: "\(tokenHost)/tok/2", seriesId: "gr42-run"),
        ])

        #expect(out.count == 1)
    }

    // Two nights WITHIN the gap window and with no token still join, or this change would have quietly
    // become the only way a run is recognised (L159).
    @Test func thegapWalkStillJoinsWhatItAlwaysJoined() {
        let out = RunGrouping.group([
            row("A Show", "2026-08-17"),
            row("A Show", "2026-08-24"),
        ])

        #expect(out.count == 1)
    }
}
