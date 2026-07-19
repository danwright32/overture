import Testing
import Foundation
import SwiftData
@testable import Overture

// #1027 Phase 2: correcting a source's URL inline, and confirming an empty page as right-as-is.
//
// The load-bearing rule here is the one the red-team caught: a corrected URL must be treated as a
// BRAND-NEW source for reconcile. The source id is kept (it is stamped on every prospect the old page
// produced), but its feed history and warmup are reset, so the new page cannot mark any of those
// prospects cancelled until it has earned its own baseline. Keep the id AND the baseline and a
// same-sized replacement page silently strikes Dan's live shows: the exact silent-cancellation hole the
// whole WatchedSource / FeedReconcile design exists to close.
@MainActor
@Suite("Fixing a source URL and confirming an empty page (#1027)")
struct WatchlistEditURLTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func sources(_ ctx: ModelContext) throws -> [WatchedSource] {
        try ctx.fetch(FetchDescriptor<WatchedSource>())
    }

    // MARK: - editURL

    @Test func fixingAUrlKeepsTheIdButResetsWarmupAndFeedHistory() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "oldhost", orgName: "Kaufman",
                              listingsURL: "https://old.example/events", kind: .html)
        s.baselineFeedCount = 12
        s.successfulCheckCount = 9
        s.degradedStreak = 2
        s.lastDegradedCount = 5
        s.lastReadableCount = 12
        s.lastUnreadableCount = 3
        s.health = .failing
        s.lastFailure = .verdict(.noDatedContent)
        s.confirmedEmptyHash = "old"
        s.lastContentHash = "old"
        s.pendingContentHash = "pend"
        s.hasUnreadChanges = false
        ctx.insert(s)
        try ctx.save()

        let r = WatchlistEditing.editURL(s, to: "https://new-calendar.example/shows", in: ctx)

        #expect(r == .saved(sourceId: "oldhost"))
        #expect(s.sourceId == "oldhost")                          // id preserved: it is on the prospects
        #expect(s.listingsURL == "https://new-calendar.example/shows")
        #expect(s.baselineFeedCount == 0)                         // re-enters warmup
        #expect(s.successfulCheckCount == 0)
        #expect(s.degradedStreak == 0)
        #expect(s.lastDegradedCount == 0)
        #expect(s.lastReadableCount == 0)
        #expect(s.lastUnreadableCount == 0)
        #expect(s.lastFailure == nil)
        #expect(s.health == .neverChecked)                        // not yet checked at the new address
        #expect(s.confirmedEmptyHash == nil)                      // a different page: nothing confirmed
        #expect(s.lastContentHash == nil)
        #expect(s.pendingContentHash == nil)
        #expect(s.hasUnreadChanges)                               // marked for a fresh read
    }

    // MARK: - setVenueLocation (#1175)

    // Setting a location must NOT reset feed history the way editURL does: the SET of shows is unchanged,
    // only their place annotation, so the source keeps its earned baseline. It IS marked for a fresh read
    // so the correction actually reaches the store on the next scout rather than waiting for the calendar
    // to change on its own.
    @Test func settingAVenueLocationStoresItAndMarksForARead() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "gr42", orgName: "The Green Room 42",
                              listingsURL: "https://thegreenroom42.venuetix.com/", kind: .html)
        s.baselineFeedCount = 20
        s.successfulCheckCount = 8
        s.hasUnreadChanges = false
        ctx.insert(s); try ctx.save()

        WatchlistEditing.setVenueLocation(s, to: "  570 Tenth Ave, New York, NY 10036  ", in: ctx)

        #expect(s.venueLocation == "570 Tenth Ave, New York, NY 10036")   // trimmed
        #expect(s.hasUnreadChanges)                                       // re-read so the fix lands
        #expect(s.baselineFeedCount == 20)                               // history untouched: same shows
        #expect(s.successfulCheckCount == 8)
    }

    @Test func clearingAVenueLocationStoresNil() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "gr42", orgName: "The Green Room 42",
                              listingsURL: "https://thegreenroom42.venuetix.com/", kind: .html)
        s.venueLocation = "New York, NY"
        ctx.insert(s); try ctx.save()

        WatchlistEditing.setVenueLocation(s, to: "   ", in: ctx)
        #expect(s.venueLocation == nil)
    }

    @Test func fixingToNonsenseIsRefused() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "org", orgName: "Org", listingsURL: "https://org.example/e", kind: .html)
        ctx.insert(s); try ctx.save()

        #expect(WatchlistEditing.editURL(s, to: "not a url", in: ctx) == .invalidURL)
        #expect(s.listingsURL == "https://org.example/e")        // unchanged
    }

    // A corrected URL that lands on a host Dan ALREADY watches as a different source is refused, or the
    // same calendar would be fetched and read twice every run.
    @Test func fixingOntoADifferentWatchedHostIsAConflict() throws {
        let ctx = try context()
        let other = WatchedSource(sourceId: "merkin", orgName: "Merkin",
                                  listingsURL: "https://merkin.example/calendar", kind: .html)
        let s = WatchedSource(sourceId: "org", orgName: "Org", listingsURL: "https://org.example/e", kind: .html)
        ctx.insert(other); ctx.insert(s); try ctx.save()

        let r = WatchlistEditing.editURL(s, to: "https://www.merkin.example/events", in: ctx)
        #expect(r == .conflict(orgName: "Merkin"))
        #expect(s.listingsURL == "https://org.example/e")        // unchanged
    }

    // The do-not-contact invariant holds by this route too: a URL cannot be corrected onto the host of
    // an org that asked Dan to stop.
    @Test func fixingOntoARefusedHostIsRefused() throws {
        let ctx = try context()
        let refused = WatchedSource(sourceId: "bargemusic", orgName: "Bargemusic",
                                    listingsURL: "https://bargemusic.org/calendar", kind: .html)
        refused.isActive = false
        refused.inactiveReason = .orgRefusal
        let s = WatchedSource(sourceId: "org", orgName: "Org", listingsURL: "https://org.example/e", kind: .html)
        ctx.insert(refused); ctx.insert(s); try ctx.save()

        let r = WatchlistEditing.editURL(s, to: "https://bargemusic.org/events", in: ctx)
        #expect(r == .refused(orgName: "Bargemusic"))
        #expect(s.listingsURL == "https://org.example/e")        // unchanged
    }

    // MARK: - confirmEmpty

    @Test func confirmingAnEmptyPageAnchorsToTheReadHashAndClearsTheFailure() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "org", orgName: "Org", listingsURL: "https://org.example/e", kind: .html)
        s.pendingContentHash = "H1"
        s.lastContentHash = "H0"
        s.hasUnreadChanges = true
        s.health = .failing
        s.lastFailure = .verdict(.noDatedContent)
        ctx.insert(s); try ctx.save()

        let r = WatchlistEditing.confirmEmpty(s, in: ctx)

        #expect(r == .confirmed)
        #expect(s.confirmedEmptyHash == "H1")                    // anchored to the bytes just read
        #expect(s.lastContentHash == "H1")                       // stamped, so the daily run sees no change
        #expect(s.pendingContentHash == nil)
        #expect(s.hasUnreadChanges == false)
        #expect(s.health == .ok)
        #expect(s.lastFailure == nil)
    }

    @Test func confirmingWithNoReadHashClearsTheDisplayButCannotAnchor() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "org", orgName: "Org", listingsURL: "https://org.example/e", kind: .html)
        s.pendingContentHash = nil
        s.lastContentHash = nil
        s.health = .failing
        s.lastFailure = .verdict(.noDatedContent)
        ctx.insert(s); try ctx.save()

        let r = WatchlistEditing.confirmEmpty(s, in: ctx)

        #expect(r == .noHash)
        #expect(s.confirmedEmptyHash == nil)                     // nothing to anchor to
        #expect(s.lastFailure == nil)                            // display cleared anyway
        #expect(s.health == .ok)
    }

    // MARK: - The silent-cancellation guard (red-team #1)

    // A source past warmup with a live prospect, whose URL Dan corrects. The next scout reads the NEW
    // page, a comparable-sized feed of different shows. The old prospect must NOT be pushed toward gone:
    // the corrected URL has to re-earn warmup first. Without the reset in editURL this test fails, and
    // the show Dan kept quietly leaves his queue.
    @Test func aCorrectedUrlCannotCancelTheOldPagesProspects() throws {
        let ctx = try context()
        let s = WatchedSource(sourceId: "kaufman", orgName: "Kaufman",
                              listingsURL: "https://old.example/events", kind: .html)
        s.successfulCheckCount = WatchedSource.warmupRuns        // past warmup on the OLD page
        s.baselineFeedCount = 2
        s.lastContentHash = "old"
        s.pendingContentHash = "old"
        ctx.insert(s)

        let live = Prospect(naturalKey: "OldShow", groupName: "OldShow", discipline: "music",
                            venue: "Kaufman", performanceDate: "2099-09-19", sourceListingURL: nil,
                            websiteURL: nil, priorRelationship: "none", production: "self",
                            profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                            fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                            possibleMatchName: nil, status: .new)
        live.sourceIds = ["kaufman"]
        live.missedScoutCount = 0
        ctx.insert(live)
        try ctx.save()

        // Dan corrects the URL, then the new page is read: two credible, DIFFERENT upcoming shows.
        _ = WatchlistEditing.editURL(s, to: "https://new.example/calendar", in: ctx)
        let results = ScoutExtractResults(
            version: 1, generatedAt: "2026-07-12T00:00:00Z",
            results: [ScoutExtractResult(sourceId: "kaufman", verdict: .upcomingListings, events: [
                ScoutExtractEvent(title: "New A", presenter: "New A", venue: "Kaufman",
                                  performanceDate: "2099-10-01", sourceUrl: "https://new.example/a"),
                ScoutExtractEvent(title: "New B", presenter: "New B", venue: "Kaufman",
                                  performanceDate: "2099-10-02", sourceUrl: "https://new.example/b")],
                note: nil)])
        _ = ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                      today: ScoutTestClock.beforeAllFixtures,
                                      now: Date(timeIntervalSince1970: 1_800_000_000), into: ctx)

        let stored = try #require(try ctx.fetch(FetchDescriptor<Prospect>())
            .first { $0.naturalKey == "OldShow" })
        #expect(stored.missedScoutCount == 0)                    // NOT reconciled toward gone
    }
}
