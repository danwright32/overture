import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("In-app scout application")
struct ScoutServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let liveEvents = [
        ExtractedEvent(title: "Boston & New York International Music Competition Winners' Recital",
                       presenter: "Jam Generation", venue: "Weill Recital Hall",
                       performanceDate: "2026-06-22", sourceUrl: "https://example.com/a"),
        ExtractedEvent(title: "Indianapolis Children's Choir", presenter: "Indianapolis Children's Choir",
                       venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-06-24",
                       sourceUrl: "https://example.com/b"),
    ]

    @Test func classifiesRanksAndInsertsExtractedEvents() throws {
        let ctx = ModelContext(try container())
        let outcome = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: [], into: ctx)

        #expect(outcome.found == 2)
        #expect(outcome.inserted == 2)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let choir = stored.first { $0.groupName.contains("Children's Choir") }
        #expect(choir?.tier == "high")          // self + strong + uncovered + choral
        let recital = stored.first { $0.groupName.contains("Competition Winners") }
        #expect(recital?.tier == "longshot")    // agency dead zone
    }

    @Test func reScoutPreservesKeepDismissAndUpdates() throws {
        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: [], into: ctx)

        // Dan keeps the choir.
        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24", venue: "Stern Auditorium / Perelman Stage")
        let choir = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        choir?.status = .queued
        try ctx.save()

        let outcome = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: [], into: ctx)
        #expect(outcome.inserted == 0)
        #expect(outcome.updated == 2)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(refreshed?.status == .queued)   // decision preserved across a re-scout
    }

    @Test func dncHistorySuppressesAProspect() throws {
        let ctx = ModelContext(try container())
        let history = [HistoryRecord(groupName: "Indianapolis Children's Choir", status: "dnc")]
        let outcome = ScoutService.apply(events: liveEvents, clients: [], history: history, blocked: [], into: ctx)

        #expect(outcome.skipped == 1)   // the DNC choir is suppressed
        #expect(outcome.inserted == 1)  // only the recital remains
    }

    @Test func reScoutRefreshesConfidenceButKeepsDansReview() throws {
        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: [], into: ctx)
        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24", venue: "Stern Auditorium / Perelman Stage")
        let choir = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(choir?.classificationConfidence == Confidence.confident.rawValue) // scout wrote a verdict

        // Dan reviews it, and pretend the scout had flagged it uncertain.
        choir?.confidenceReviewedByDan = true
        choir?.classificationConfidence = Confidence.uncertain.rawValue
        try ctx.save()

        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: [], into: ctx)
        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(refreshed?.confidenceReviewedByDan == true)                          // Dan-owned, preserved
        #expect(refreshed?.classificationConfidence == Confidence.confident.rawValue) // scout-owned, refreshed
    }

    @Test func titleDriftWithSameSourceURLCarriesTheDecisionForward() throws {
        let ctx = ModelContext(try container())
        let url = "https://www.carnegiehall.org/event/abc-123"
        let first = ExtractedEvent(title: "Acme Festival Chorus", presenter: "Acme Festival Chorus",
                                   venue: "Weill Recital Hall", performanceDate: "2026-07-01", sourceUrl: url)
        _ = ScoutService.apply(events: [first], clients: [], history: [], blocked: [], into: ctx)

        // Dan dismisses it.
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.status != .dismissed }
        p?.status = .dismissed
        try ctx.save()

        // Re-scout: the venue tweaked the listing title, but the source URL is unchanged.
        let drifted = ExtractedEvent(title: "Acme Festival Chorus — Summer Concert", presenter: "Acme Festival Chorus",
                                     venue: "Weill Recital Hall", performanceDate: "2026-07-01", sourceUrl: url)
        let outcome = ScoutService.apply(events: [drifted], clients: [], history: [], blocked: [], into: ctx)

        #expect(outcome.inserted == 0)                                    // no orphaned duplicate
        #expect(outcome.updated == 1)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1)                                          // still one record
        #expect(all.first?.status == .dismissed)                         // Dan's decision carried forward
        #expect(all.first?.groupName == "Acme Festival Chorus — Summer Concert") // refreshed to new title
    }
}
