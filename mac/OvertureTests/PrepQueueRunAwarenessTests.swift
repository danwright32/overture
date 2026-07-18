import Testing
import Foundation
import SwiftData
@testable import Overture

// #1122 (surface 3, Dan's priority note): the Prep run must know when a kept show is a multi-night run
// whose OPENING night has already passed, so it pitches only the remaining dates and never references the
// gone opening night. The queue item now carries `runEndDate` and a derived `openingNightPassed`, computed
// with Swift's reliable date math rather than left to the drafter to infer.
@Suite("Prep is aware of a run's range and passed opening (#1122)")
struct PrepQueueRunAwarenessTests {
    // MARK: - The derived signal (pure)

    // A run whose opening night is behind us but whose closing night is still ahead is underway: the
    // opening has passed and there are dates left to pitch.
    @Test func aRunUnderwayHasItsOpeningNightPassed() {
        #expect(PrepQueueBuilder.openingNightPassed(
            performanceDate: "2026-07-17", runEndDate: "2026-07-25", today: "2026-07-20"))
    }

    // An upcoming run (opening still ahead) has not passed its opening night.
    @Test func anUpcomingRunHasNotPassedItsOpening() {
        #expect(!PrepQueueBuilder.openingNightPassed(
            performanceDate: "2026-07-27", runEndDate: "2026-08-02", today: "2026-07-20"))
    }

    // A fully past run (even its closing night is behind us) is not "opening passed, dates remain": there
    // are no dates left to pitch, so the signal is false, not true.
    @Test func aFullyPastRunIsNotFlaggedAsUnderway() {
        #expect(!PrepQueueBuilder.openingNightPassed(
            performanceDate: "2026-07-10", runEndDate: "2026-07-15", today: "2026-07-20"))
    }

    // A single-night show (no runEndDate) never carries the signal: whether it is past or upcoming, there
    // is no "opening passed but later dates remain" case for a one-night show.
    @Test func aSingleNightShowNeverCarriesTheSignal() {
        #expect(!PrepQueueBuilder.openingNightPassed(
            performanceDate: "2026-07-17", runEndDate: nil, today: "2026-07-20"))
        #expect(!PrepQueueBuilder.openingNightPassed(
            performanceDate: "2026-07-27", runEndDate: nil, today: "2026-07-20"))
    }

    // Opening night is TODAY: it has not gone by yet, so the run is not flagged.
    @Test func aRunOpeningTodayIsNotYetPassed() {
        #expect(!PrepQueueBuilder.openingNightPassed(
            performanceDate: "2026-07-20", runEndDate: "2026-07-25", today: "2026-07-20"))
    }

    // MARK: - The handoff carries it

    @MainActor
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @MainActor
    @discardableResult
    private func kept(_ ctx: ModelContext, key: String, open: String?, close: String?) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Merkin Hall",
                         performanceDate: open, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)   // kept, no draft -> prep-eligible
        p.runEndDate = close
        ctx.insert(p)
        return p
    }

    // The built queue item carries the run's closing night and, for a run underway, the passed-opening
    // signal, so the Prep run has both without having to do date math itself.
    @MainActor
    @Test func buildQueueCarriesTheRunRangeAndPassedOpening() throws {
        let ctx = try context()
        kept(ctx, key: "underway", open: "2026-07-17", close: "2026-07-25")
        kept(ctx, key: "single", open: "2026-07-27", close: nil)

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "2026-07-20T00:00:00.000Z",
                                                today: "2026-07-20")
        let underway = queue.items.first { $0.naturalKey == "underway" }
        let single = queue.items.first { $0.naturalKey == "single" }

        #expect(underway?.runEndDate == "2026-07-25")
        #expect(underway?.openingNightPassed == true)
        #expect(single?.runEndDate == nil)
        // An upcoming single-night show carries no passed-opening signal (absent, not false-positive).
        #expect(single?.openingNightPassed == nil)
    }
}
