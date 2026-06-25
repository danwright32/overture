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

    // #60 Task 3: Dan's corrected classification must survive a re-scout.
    // Set up an existing prospect whose discipline was corrected to "dance" by Dan
    // (classificationOverriddenByDan = true). Run apply with a fresh event that the
    // classifier produces as "choral". The prospect's discipline must stay "dance" and
    // fitScore must reflect dance (not the scout's choral value).
    @Test func reScoutPreservesDansCorrectedClassification() throws {
        let ctx = ModelContext(try container())

        // Build the natural key the incoming event will produce.
        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24",
                                          venue: "Stern Auditorium / Perelman Stage")

        // Dance score (no prior): discipline 3 + self 2 + strong 2 + likely_uncovered 2 = 9.
        let existing = Prospect(naturalKey: key, groupName: "Indianapolis Children's Choir",
                                discipline: "dance", venue: "Stern Auditorium / Perelman Stage",
                                performanceDate: "2026-06-24", sourceListingURL: nil, websiteURL: nil,
                                priorRelationship: "none", production: "self", profile: "strong",
                                coverage: "likely_uncovered", fitScore: 9, tier: "high",
                                fitReason: "corrected", matchedClientName: nil,
                                possibleMatchSource: nil, possibleMatchName: nil)
        existing.classificationOverriddenByDan = true
        ctx.insert(existing)
        try ctx.save()

        // Scout re-runs; the classifier produces choral for this event (score = 7).
        let choirEvent = ExtractedEvent(title: "Indianapolis Children's Choir",
                                        presenter: "Indianapolis Children's Choir",
                                        venue: "Stern Auditorium / Perelman Stage",
                                        performanceDate: "2026-06-24",
                                        sourceUrl: "https://example.com/b")
        _ = ScoutService.apply(events: [choirEvent], clients: [], history: [], blocked: [], into: ctx)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.naturalKey == key })).first
        // Dan's discipline must survive the re-scout.
        #expect(refreshed?.discipline == "dance")
        // fitScore must be re-derived from dance (9), not copied from the scout's choral result (7).
        #expect(refreshed?.fitScore == 9)
        // The override flag itself must be untouched.
        #expect(refreshed?.classificationOverriddenByDan == true)
    }

    // #133: a kept Carnegie prospect that drops out of the feed accrues misses and, after two
    // consecutive ones, reads as gone — while one that's still present stays at zero.
    @Test func disappearedCarnegieProspectAccruesMissesAcrossScouts() throws {
        let ctx = ModelContext(try container())
        let future = "2026-12-01"
        let x = ExtractedEvent(title: "Future Choir X", presenter: "Future Choir X",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/x")
        let y = ExtractedEvent(title: "Future Choir Y", presenter: "Future Choir Y",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/y")
        _ = ScoutService.apply(events: [x], clients: [], history: [], blocked: [], into: ctx)
        let xKey = Prospect.makeNaturalKey(groupName: "Future Choir X", performanceDate: future, venue: "Weill Recital Hall")
        func xRow() throws -> Prospect { try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == xKey })).first! }
        #expect(try xRow().missedScoutCount == 0)

        // X is absent from a healthy (non-empty) feed: one miss, not yet gone.
        _ = ScoutService.apply(events: [y], clients: [], history: [], blocked: [], into: ctx)
        #expect(try xRow().missedScoutCount == 1)
        #expect(try xRow().disappearedFromFeed == false)

        // Absent again: two misses, now gone.
        _ = ScoutService.apply(events: [y], clients: [], history: [], blocked: [], into: ctx)
        #expect(try xRow().disappearedFromFeed == true)

        // X reappears: counter resets.
        _ = ScoutService.apply(events: [x], clients: [], history: [], blocked: [], into: ctx)
        #expect(try xRow().missedScoutCount == 0)
    }

    // #150: a degraded (suspiciously small vs baseline) feed must not accrue misses through apply.
    @Test func applyWithDegradedFeedDoesNotAccrueMisses() throws {
        let ctx = ModelContext(try container())
        let future = "2026-12-01"
        let x = ExtractedEvent(title: "Future Choir X", presenter: "Future Choir X",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/x")
        let y = ExtractedEvent(title: "Future Choir Y", presenter: "Future Choir Y",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/y")
        _ = ScoutService.apply(events: [x], clients: [], history: [], blocked: [], into: ctx)
        let xKey = Prospect.makeNaturalKey(groupName: "Future Choir X", performanceDate: future, venue: "Weill Recital Hall")
        func xRow() throws -> Prospect { try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == xKey })).first! }

        // Tiny feed (only y) but a large healthy baseline → feed looks degraded → X is NOT a miss.
        _ = ScoutService.apply(events: [y], clients: [], history: [], blocked: [], baselineFeedCount: 80, into: ctx)
        #expect(try xRow().missedScoutCount == 0)
    }

    // #156: the scout's blocked set is Downbeat's exported blockedDates unioned with the local
    // override file, deduplicated.
    @Test func mergedBlockedDatesUnionsExportAndLocalOverride() {
        let merged = ScoutService.mergedBlockedDates(
            exportBlocked: ["2026-03-10", "2026-03-11"],
            localOverride: ["2026-03-11", "2026-04-01"])
        #expect(merged == ["2026-03-10", "2026-03-11", "2026-04-01"])
    }

    @Test func healthyFeedCountPersistenceRoundTrips() {
        let defaults = UserDefaults(suiteName: "feedcount-\(UUID().uuidString)")!
        #expect(ScoutService.lastHealthyFeedCount(in: defaults) == 0)   // unset = no baseline
        ScoutService.recordHealthyFeedCount(42, in: defaults)
        #expect(ScoutService.lastHealthyFeedCount(in: defaults) == 42)
    }

    @Test func collapsesAConsecutiveRunIntoOneProspect() throws {
        let ctx = ModelContext(try container())
        let events = [
            ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-14", sourceUrl: "u14"),
            ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-15", sourceUrl: "u15"),
            ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-16", sourceUrl: "u16"),
        ]
        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)
        #expect(stored[0].performanceDate == "2026-07-14")
        #expect(stored[0].runEndDate == "2026-07-16")
        #expect(outcome.inserted == 1)
    }

    @Test func reRecognizesARunWhoseOpeningNightAgedOut() throws {
        let ctx = ModelContext(try container())
        let day1 = [
            ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-14", sourceUrl: "n14"),
            ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-15", sourceUrl: "n15"),
        ]
        _ = ScoutService.apply(events: day1, clients: [], history: [], blocked: [], into: ctx)
        let kept = try ctx.fetch(FetchDescriptor<Prospect>())[0]
        kept.statusRaw = "dismissed"   // Dan's decision
        try? ctx.save()

        // Next scout: the 14th has aged out of the window; only the 15th remains.
        let day2 = [ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-15", sourceUrl: "n15")]
        _ = ScoutService.apply(events: day2, clients: [], history: [], blocked: [], into: ctx)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)               // re-attached, not duplicated
        #expect(stored[0].statusRaw == "dismissed")  // decision preserved
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
