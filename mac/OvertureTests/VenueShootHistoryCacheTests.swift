import Testing
import Foundation
import SwiftData
import Observation
@testable import Overture

// #1964, measured with `sample` against the live Release build on 2026-08-01 while diagnosing why
// dismissing a show is slow: `VenueShootHistory.current(today:)` opens and decodes the shoot-history file
// AND the Downbeat export, and it was being called from inside `QueueModel.items`, which runs on every
// render pass. About 430 samples on the main thread, and a sample count understates blocking I/O.
//
// Its own doc comment says callers build it ONCE per pass and never per row. The queue honoured that
// literally while calling it once per RENDER, which is a different thing entirely.
//
// The same shape as #1770's Gmail answer: one cached value, refreshed at the moments it can change, and
// never read from disk while drawing.
@MainActor
@Suite("The shoot history is held, not re-read on every render (#1964)")
struct VenueShootHistoryCacheTests {
    // A settable source the injected loader reads, so a test can change what the files say between
    // refreshes without capturing a mutable local in an escaping closure.
    private final class Source {
        var shoots: [ShootRecord]
        var loads = 0
        init(_ shoots: [ShootRecord]) { self.shoots = shoots }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.lock(); value = true; lock.unlock() }
        var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func shoot(_ venue: String, _ date: String) -> ShootRecord {
        ShootRecord(venue: venue, date: date, title: "An evening of song")
    }

    private func cache(_ source: Source, today: String = "2026-08-02") -> VenueShootHistoryCache {
        VenueShootHistoryCache(today: today, load: { day in
            source.loads += 1
            return VenueShootHistory(shoots: source.shoots, bookings: [], today: day)
        })
    }

    // The whole point: drawing asks the filesystem nothing, however many times it draws.
    @Test func everyReadAfterTheFirstCostsNoFileAtAll() {
        let source = Source([shoot("SoHo Playhouse", "2026-01-10")])
        let held = cache(source)

        for _ in 0..<50 { _ = held.history(today: "2026-08-02") }

        #expect(source.loads == 1)
        #expect(held.history(today: "2026-08-02").band(for: "SoHo Playhouse") == .shotBefore)
    }

    // The moments it can change are what refresh it: launch, the reconcile tick, and the export watcher
    // firing. A history imported while the app is open reaches the cards on the next of those.
    @Test func aRefreshGoesBackToTheFiles() {
        let source = Source([])
        let held = cache(source)
        #expect(held.history(today: "2026-08-02").band(for: "SoHo Playhouse") == nil)

        source.shoots = [shoot("SoHo Playhouse", "2026-01-10")]
        held.refresh(today: "2026-08-02")

        #expect(source.loads == 2)
        #expect(held.history(today: "2026-08-02").band(for: "SoHo Playhouse") == .shotBefore)
    }

    // A held value has to know what day it was built for. The history counts only shoots strictly before
    // today, so serving yesterday's answer across midnight would count tonight's show as already shot.
    @Test func aNewDayRebuildsWithoutBeingAsked() {
        let source = Source([shoot("SoHo Playhouse", "2026-08-02")])
        let held = cache(source, today: "2026-08-02")
        #expect(held.history(today: "2026-08-02").band(for: "SoHo Playhouse") == nil)

        let tomorrow = held.history(today: "2026-08-03")

        #expect(source.loads == 2)
        #expect(tomorrow.band(for: "SoHo Playhouse") == .shotBefore)
    }

    // #1930's rule, and the reason this cache does not itself become a cost: the reconcile tick refreshes
    // it on a schedule, and a tick that finds the same history must not invalidate the queue that reads it.
    @Test func aRefreshThatFindsNothingNewNotifiesNobody() {
        let source = Source([shoot("SoHo Playhouse", "2026-01-10")])
        let held = cache(source)
        let notified = Flag()
        withObservationTracking { _ = held.current } onChange: { notified.raise() }

        held.refresh(today: "2026-08-02")

        #expect(source.loads == 2)   // it really did go and look
        #expect(!notified.raised, "an unchanged history must not invalidate the queue reading it")
    }

    // The other half, which matters more: a history that HAS changed must reach every surface showing it.
    // A "don't notify" guard that over-applied would leave a card claiming a room Dan has never shot.
    @Test func aRefreshThatFindsAChangeStillNotifies() {
        let source = Source([])
        let held = cache(source)
        let notified = Flag()
        withObservationTracking { _ = held.current } onChange: { notified.raise() }

        source.shoots = [shoot("SoHo Playhouse", "2026-01-10")]
        held.refresh(today: "2026-08-02")

        #expect(notified.raised)
    }

    // The failure path. No import has been run, which is a normal state rather than a fault, so the cache
    // holds an empty history and says nothing. It must not remember that emptiness as final: the import is
    // a manual step Dan runs while the app is open, and the next refresh has to pick it up.
    @Test func aHistoryImportedAfterLaunchIsPickedUpRatherThanCachedAsEmptyForever() {
        let source = Source([])
        let held = cache(source)
        #expect(held.current.shoots(for: "SoHo Playhouse").isEmpty)

        source.shoots = [shoot("SoHo Playhouse", "2026-01-10"), shoot("SoHo Playhouse", "2026-02-11")]
        held.refresh(today: "2026-08-02")

        #expect(held.current.band(for: "SoHo Playhouse") == .aFew)
    }
}

// The queue's side of the same change: the derivation is HANDED a history rather than sourcing one, the
// way every card is handed the Gmail answer (#1770).
@MainActor
@Suite("The queue derives from the history it is given (#1964)")
struct QueueItemsVenueHistoryTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext, venue: String) -> Prospect {
        let p = Prospect(naturalKey: "k-\(venue)", groupName: "Aurora Strings", discipline: "music",
                         venue: venue, performanceDate: "2026-11-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        ctx.insert(p)
        return p
    }

    // The discriminating case: a band that could only have come from the history handed in. If the
    // derivation still sourced its own from disk, this Mac's real file has never heard of the room.
    @Test func aBandComesFromTheHistoryHandedIn() throws {
        let ctx = ModelContext(try container())
        show(ctx, venue: "SoHo Playhouse")
        let history = VenueShootHistory(
            shoots: [ShootRecord(venue: "SoHo Playhouse", date: "2026-01-10", title: "An evening of song"),
                     ShootRecord(venue: "SoHo Playhouse", date: "2026-02-11", title: "A second night")],
            bookings: [], today: "2026-08-02")

        let items = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()), history: history)

        #expect(items.first?.venueHistoryBand == .aFew)
        #expect(items.first?.venueHistoryShoots.count == 2)
    }

    // And an empty one says nothing, rather than falling back to whatever is on disk.
    @Test func anEmptyHistoryLeavesTheCardSilent() throws {
        let ctx = ModelContext(try container())
        show(ctx, venue: "SoHo Playhouse")
        let history = VenueShootHistory(shoots: [], bookings: [], today: "2026-08-02")

        let items = QueueModel.items(from: try ctx.fetch(FetchDescriptor<Prospect>()), history: history)

        #expect(items.first?.venueHistoryBand == nil)
    }
}

// The wiring. The cache can be perfect and the queue can still read the files on every render if the
// render path does not actually use it, and no running test can evaluate QueueView's body (its @Query
// properties need a live container), so this guards the shape the way QueueInvalidationGuardTests does.
@Suite("The render path reads the held history, and something refreshes it (#1964)")
struct VenueShootHistoryWiringTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    private var archiveView: String { SourceGuardHelper.source("Overture/UI/ArchiveView.swift") }
    private var scheduler: String { SourceGuardHelper.source("Overture/App/ReconcileScheduler.swift") }

    // BOTH render paths hand one in. The parameter falls back to reading the files when it is given
    // nothing, which is right for a caller with no cache in hand (a unit test, a one-off build) and is
    // exactly the trap on a render path, so each of the two is pinned rather than assumed. Archive is the
    // one that would have been missed: it derives the same items and it redraws just as often.
    @Test func theQueuePassesTheHeldHistoryIntoTheDerivation() {
        #expect(!queueView.isEmpty)
        #expect(queueView.contains("history: VenueShootHistoryCache.shared.history()"))
    }

    @Test func archivePassesTheHeldHistoryToo() {
        #expect(!archiveView.isEmpty)
        #expect(archiveView.contains("history: VenueShootHistoryCache.shared.history()"))
    }

    // The refresh rides the safe reconcile tick, which is launch, the periodic run, and the export
    // watcher firing, the same free tick the cached Gmail signature already uses (#1158).
    @Test func theSafeTickRefreshesTheHeldHistory() {
        guard let tick = SourceGuardHelper.propertyBody("func runSafeReconcilesOnce(now: Date = Date()) async -> ReconcileSummary {",
                                                        in: scheduler) else {
            Issue.record("expected to find runSafeReconcilesOnce")
            return
        }
        #expect(tick.contains("VenueShootHistoryCache.shared.refresh()"))
    }
}
