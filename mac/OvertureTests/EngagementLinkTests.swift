import Testing
import Foundation

// #939: a same-production show performed at DIFFERENT venues on nearby dates (a recurring Carnegie
// community-calendar pattern) is stored as separate Prospect rows, one per venue, with no relationship
// recorded between them. RunGrouping only ever collapses nights at the SAME venue, so it never sees this
// case. EngagementLink is the second pass: it links rows across venues so the day-off offer (and later,
// display) can act on the whole engagement instead of just the one row Dan happened to dismiss.
private func row(_ id: String, _ group: String, _ date: String?, venue: String?, runEndDate: String? = nil) -> EngagementLink.Row {
    EngagementLink.Row(id: id, groupName: group, venue: venue, performanceDate: date, runEndDate: runEndDate)
}

@Suite("Engagement linking across venues (#939)")
struct EngagementLinkTests {
    @Test func linksTheSameTitleAtTwoDifferentVenuesWithinTheGap() {
        // The actual #939 example: "MOCA PERFORMS..." at Open Door Senior Center on the 24th,
        // Museum of Chinese in America on the 25th.
        let out = EngagementLink.group([
            row("moca-25", "MOCA PERFORMS", "2026-07-25", venue: "Museum of Chinese in America"),
            row("moca-24", "MOCA PERFORMS", "2026-07-24", venue: "Open Door Senior Center"),
        ])
        #expect(out["moca-25"] == [EngagementLink.Member(venue: "Open Door Senior Center", date: "2026-07-24")])
        #expect(out["moca-24"] == [EngagementLink.Member(venue: "Museum of Chinese in America", date: "2026-07-25")])
    }

    @Test func doesNotLinkTheSameTitleAtDifferentVenuesBeyondTheGap() {
        let out = EngagementLink.group([
            row("1", "Holiday Concert", "2026-07-01", venue: "Hall A"),
            row("2", "Holiday Concert", "2026-07-20", venue: "Hall B"),
        ])
        #expect(out["1"] == nil)
        #expect(out["2"] == nil)
    }

    // Three community venues on a short tour must all link together, not just adjacent pairs: dismissing
    // the FIRST date's row must still know about the THIRD date, two gaps away.
    @Test func chainsThaldernuesTransitively() {
        let out = EngagementLink.group([
            row("1", "Little Red Riding Hood", "2026-07-20", venue: "Venue A"),
            row("2", "Little Red Riding Hood", "2026-07-22", venue: "Venue B"),
            row("3", "Little Red Riding Hood", "2026-07-24", venue: "Venue C"),
        ])
        #expect(Set(out["1"] ?? []) == Set([
            EngagementLink.Member(venue: "Venue B", date: "2026-07-22"),
            EngagementLink.Member(venue: "Venue C", date: "2026-07-24"),
        ]))
        #expect(Set(out["3"] ?? []) == Set([
            EngagementLink.Member(venue: "Venue A", date: "2026-07-20"),
            EngagementLink.Member(venue: "Venue B", date: "2026-07-22"),
        ]))
    }

    // A multi-night run collapsed at one venue (its own runEndDate already set by RunGrouping) still
    // measures the gap to the NEXT venue from its closing night, not its opening night.
    @Test func measuresTheGapFromAMultiNightRunsClosingNight() {
        let out = EngagementLink.group([
            row("1", "Tour", "2026-07-01", venue: "Venue A", runEndDate: "2026-07-03"),
            row("2", "Tour", "2026-07-06", venue: "Venue B"),
        ])
        #expect(out["1"] == [EngagementLink.Member(venue: "Venue B", date: "2026-07-06")])
    }

    // Separate runs of the same act at the SAME venue are RunGrouping's existing job
    // (partOfRelatedRun); EngagementLink must stay out of that case, not double-report it.
    @Test func doesNotReportASingleVenueClusterEvenWithinTheGap() {
        let out = EngagementLink.group([
            row("1", "Solo Recital", "2026-07-01", venue: "Weill Recital Hall"),
            row("2", "Solo Recital", "2026-07-02", venue: "Weill Recital Hall"),
        ])
        #expect(out["1"] == nil)
        #expect(out["2"] == nil)
    }

    // GroupNameMatch.isConfident accepts a general ceremony title as a confident match for its own
    // differently-titled sub-event (RunGroupingTests' own fixture: "Golden Classical Music Awards
    // Ceremony" contained as a contiguous prefix of "...Ceremony Guest Artist: Aurelia Faidley-Solars,
    // Cello") via CONTAINMENT, not exact equality. That containment rule is safe inside RunGrouping,
    // which only ever compares rows already known to be at the same venue; reused unmodified across
    // every venue in the app, it would risk wrongly linking two unrelated shows that merely share a
    // long common prefix. EngagementLink requires an EXACT normalized title match instead, so two
    // DIFFERENT venues carrying this same pair must NOT link.
    @Test func doesNotLinkOnLooseContainmentEvenThoughGroupNameMatchWould() {
        let general = "Golden Classical Music Awards Ceremony"
        let subEvent = "Golden Classical Music Awards Ceremony Guest Artist: Aurelia Faidley-Solars, Cello"
        #expect(GroupNameMatch.isConfident(general, subEvent))
        let out = EngagementLink.group([
            row("1", general, "2026-07-01", venue: "Hall A"),
            row("2", subEvent, "2026-07-02", venue: "Hall B"),
        ])
        #expect(out["1"] == nil)
        #expect(out["2"] == nil)
    }

    @Test func undatedRowsAreNeverLinked() {
        let out = EngagementLink.group([
            row("1", "Undated", nil, venue: "Hall A"),
            row("2", "Undated", nil, venue: "Hall B"),
        ])
        #expect(out.isEmpty)
    }
}
