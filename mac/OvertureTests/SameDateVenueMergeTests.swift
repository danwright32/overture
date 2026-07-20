import Testing
import Foundation
import SwiftData
@testable import Overture

// #1236: DCINY lists one concert as several per-conductor rows on the same date and venue. For a
// merge-flagged source we stamp a synthetic same-date+venue seriesId at ingest so the existing
// RunGrouping collapse fuses them into ONE prospect, whose name is the list of all conductor titles.
@Suite("Same date + venue merge (#1236)")
struct SameDateVenueMergeTests {

    private func event(_ title: String, date: String? = "2026-11-16",
                       venue: String? = "Stern Auditorium / Perelman Stage",
                       seriesId: String? = nil, url: String? = nil) -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: "DCINY", venue: venue, performanceDate: date,
                       sourceUrl: url ?? "https://dciny.org/opportunities/#\(title)", location: "New York, NY",
                       seriesId: seriesId)
    }

    // Three per-conductor rows on one date at one venue get the SAME synthetic seriesId, so they will
    // collapse. The id is namespaced so a downstream reader can tell a synthetic merge from a real feed id.
    @Test func stampsOneSyntheticIdPerDateAndVenue() {
        let out = SameDateVenueMerge.stamped([
            event("We Sing Noel"), event("Craig Courtney"), event("The Four Freedoms"),
        ])
        let ids = out.map(\.seriesId)
        #expect(ids.allSatisfy { SameDateVenueMerge.isMerged($0) })
        #expect(Set(ids.compactMap { $0 }).count == 1)   // one shared id, so one merged event
    }

    // A different date, or a different venue, is a genuinely different concert and must NOT share the id.
    @Test func doesNotShareIdAcrossDateOrVenue() {
        let out = SameDateVenueMerge.stamped([
            event("A", date: "2026-11-16"),
            event("B", date: "2026-11-17"),                                   // different date
            event("C", date: "2026-11-16", venue: "Zankel Hall"),             // different venue
        ])
        #expect(Set(out.compactMap(\.seriesId)).count == 3)                    // three distinct ids
    }

    // A real feed seriesId (VenueTix, #1174) wins: never overwrite a source's own production id, and never
    // invent one for a row that has no date or no venue to key on.
    @Test func leavesExistingIdAndUnkeyableRowsAlone() {
        let out = SameDateVenueMerge.stamped([
            event("Has real id", seriesId: "gr42-run"),
            event("No date", date: nil),
            event("No venue", venue: nil),
        ])
        #expect(out[0].seriesId == "gr42-run")
        #expect(out[1].seriesId == nil)
        #expect(out[2].seriesId == nil)
    }

    // The merged name is every row's title, in listing order, deduped, joined. The conductor list IS the
    // name until /see-a-show/ names the concert (Half B, filed separately).
    @Test func combinedNameListsEveryTitleInOrderDeduped() {
        #expect(SameDateVenueMerge.combinedName(from: ["We Sing Noel", "Craig Courtney", "The Four Freedoms"])
                == "We Sing Noel; Craig Courtney; The Four Freedoms")
        #expect(SameDateVenueMerge.combinedName(from: ["A", "A", "B"]) == "A; B")   // deduped
    }

    // End to end through the real ingest pipeline: three per-conductor rows collapse to ONE prospect
    // carrying all three conductor names, on one date (not a multi-night span). Without the flag they
    // stay three prospects.
    @MainActor
    @Test func flaggedSourceMergesToOneNamedProspect() throws {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        let events = [event("We Sing Noel", url: "https://dciny.org/a"),
                      event("Craig Courtney", url: "https://dciny.org/b"),
                      event("The Four Freedoms", url: "https://dciny.org/c")]

        _ = ScoutService.apply(events: SameDateVenueMerge.stamped(events), clients: [], history: [],
                               blocked: .empty, today: "2026-07-01", into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)
        let merged = try #require(stored.first)
        #expect(merged.groupName == "We Sing Noel; Craig Courtney; The Four Freedoms")
        #expect(merged.performanceDate == "2026-11-16")
        #expect(merged.runEndDate == nil)   // one date, not a span
    }

    @MainActor
    @Test func unflaggedSourceKeepsPerConductorRowsSeparate() throws {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        let events = [event("We Sing Noel", url: "https://dciny.org/a"),
                      event("Craig Courtney", url: "https://dciny.org/b"),
                      event("The Four Freedoms", url: "https://dciny.org/c")]

        _ = ScoutService.apply(events: events, clients: [], history: [],
                               blocked: .empty, today: "2026-07-01", into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 3)   // no flag, no merge
    }
}
