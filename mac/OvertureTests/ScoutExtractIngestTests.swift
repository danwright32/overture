import Testing
import Foundation
import SwiftData

// #802 slice 3: what the app does with what the extract run read.
//
// This is where the watchlist finally writes to the store, and where the two most dangerous mistakes in
// the whole feature live: stamping a content hash for a page we did not actually ingest (the source
// then fetches fine, reports fine, and silently ingests nothing forever), and letting a broken page
// read as a quiet one.
@MainActor
@Suite("Ingesting what the extract run read (#802)")
struct ScoutExtractIngestTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // A source we fetched, pinned and queued: it is waiting on the run to tell it what was on the page.
    @discardableResult
    private func queuedSource(_ ctx: ModelContext, id: String = "org",
                              pending: String = "new-hash",
                              lastIngested: String? = "old-hash") -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.lastContentHash = lastIngested
        s.pendingContentHash = pending
        s.hasUnreadChanges = true
        ctx.insert(s)
        return s
    }

    private func results(_ sourceId: String, verdict: PageVerdict,
                         events: [ScoutExtractEvent] = []) -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: sourceId, verdict: verdict,
                                                         events: events, note: nil)])
    }

    private func event(_ title: String, date: String = "2099-09-19") -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: title, venue: "Merkin Hall",
                          performanceDate: date, sourceUrl: "https://org.example/\(title)")
    }

    private func ingest(_ r: ScoutExtractResults, into ctx: ModelContext) -> ScoutService.Outcome {
        ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                  today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)
    }

    // MARK: - The happy path

    @Test func aReadPageBecomesProspectsStampedWithItsSource() throws {
        let ctx = try context()
        queuedSource(ctx)

        let outcome = ingest(results("org", verdict: .upcomingListings,
                                     events: [event("Brooklyn Youth Chorus")]), into: ctx)

        #expect(outcome.inserted == 1)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.first?.sourceIds == ["org"])   // #771 provenance, from a watched source
    }

    // THE rule of this slice. The hash is promoted ONLY after the ingest actually saved.
    @Test func theContentHashIsStampedOnlyAfterASuccessfulIngest() throws {
        let ctx = try context()
        let s = queuedSource(ctx, pending: "new-hash", lastIngested: "old-hash")

        ingest(results("org", verdict: .upcomingListings, events: [event("A Show")]), into: ctx)

        #expect(s.lastContentHash == "new-hash")   // we read this page and landed it
        #expect(s.pendingContentHash == nil)       // nothing left in flight
        #expect(s.hasUnreadChanges == false)       // and nothing is waiting to be read
    }

    @Test func aSuccessfulIngestCountsTowardTheWarmupAndTheHealthRecord() throws {
        let ctx = try context()
        let s = queuedSource(ctx)

        ingest(results("org", verdict: .upcomingListings, events: [event("A Show")]), into: ctx)

        #expect(s.successfulCheckCount == 1)
        #expect(s.lastSucceededAt == now)
        #expect(s.health == .ok)
        #expect(s.lastFailure == nil)
        #expect(s.baselineFeedCount == 1)          // its own baseline, never a shared one (#801)
    }

    // MARK: - A page that came back useless

    // A page whose calendar is drawn by JavaScript, or that carries no dated listings at all, is BROKEN.
    // Its hash must NOT be stamped, or we would never look at it again: it would report as healthy and
    // unchanged forever, having never once been read.
    @Test func anUnreadablePageIsNamedAsAFailureAndItsHashIsNotStamped() throws {
        let ctx = try context()
        let s = queuedSource(ctx, pending: "new-hash", lastIngested: "old-hash")

        let outcome = ingest(results("org", verdict: .unreadable), into: ctx)

        #expect(s.health == .failing)
        #expect(s.lastFailure == .verdict(.unreadable))
        #expect(s.lastContentHash == "old-hash")   // NOT promoted: we never read this page
        #expect(s.hasUnreadChanges)                // there is still something here we have not read
        #expect(s.successfulCheckCount == 0)       // a page we could not read is not a check that worked
        #expect(outcome.failedSources.map(\.sourceId) == ["org"])

        // And it stays watched. Only an org's refusal or Dan's removal takes a source off the list.
        #expect(s.isActive)
    }

    @Test func aPageWithNoDatedContentIsAlsoAFailure() throws {
        let ctx = try context()
        let s = queuedSource(ctx)

        ingest(results("org", verdict: .noDatedContent), into: ctx)

        #expect(s.health == .failing)
        #expect(s.lastFailure == .verdict(.noDatedContent))
    }

    // #1055: a couldn't-be-checked result carries the very page URL it was about, so the end-of-scout
    // popup can show (and open) it without sending Dan to the Sources sheet to find out which page was
    // flagged. This is the failed source's own listingsURL, threaded onto its SourceResult.
    @Test func aFailedSourceCarriesItsListingsURLForThePopup() throws {
        let ctx = try context()
        queuedSource(ctx, id: "protestra")   // listingsURL: https://protestra.example/events

        let outcome = ingest(results("protestra", verdict: .noDatedContent), into: ctx)

        let failed = outcome.failedSources.first { $0.sourceId == "protestra" }
        #expect(failed?.listingsURL == "https://protestra.example/events")
    }

    // MARK: - #1012: a page the run could only read PART of

    // A partial read's real events are safe to ingest (FeedReconcile can never let this verdict argue a
    // show is gone, since absenceIsEvidence gates on upcomingListings), but the hash must never latch:
    // the rest of the page is still out there and the next scout has to go back for it.
    @Test func aPartiallyReadPageIngestsItsEventsButNeverLatchesTheHash() throws {
        let ctx = try context()
        let s = queuedSource(ctx, pending: "new-hash", lastIngested: "old-hash")

        let outcome = ingest(results("org", verdict: .incompleteExtraction,
                                     events: [event("A Show")]), into: ctx)

        #expect(outcome.inserted == 1)                  // the real event it DID find lands
        #expect(s.health == .ok)                        // it is not a failure
        #expect(s.lastFailure == nil)
        #expect(s.lastContentHash == "old-hash")         // NOT promoted: more of this page is unread
        #expect(s.pendingContentHash == "new-hash")      // still in flight, for the next scout to finish
        #expect(s.hasUnreadChanges)                      // there is still something here to read
        #expect(outcome.failedSources.isEmpty)
    }

    // A partial count must not corrupt the baseline/warmup math: a page that is genuinely this size
    // would otherwise look like a shrinking calendar after enough incomplete reads.
    @Test func aPartiallyReadPageDoesNotAdvanceTheBaselineOrWarmup() throws {
        let ctx = try context()
        let s = queuedSource(ctx)
        s.baselineFeedCount = 40
        s.successfulCheckCount = 3

        ingest(results("org", verdict: .incompleteExtraction, events: [event("A Show")]), into: ctx)

        #expect(s.baselineFeedCount == 40)
        #expect(s.successfulCheckCount == 3)
    }

    // The run's own explanation still lands on the source, exactly as it does for every other verdict,
    // so Dan can read what made this page hard even though nothing failed.
    @Test func aPartiallyReadPageKeepsTheRunsNote() throws {
        let ctx = try context()
        let s = queuedSource(ctx)

        ScoutExtractIngest.ingest(
            ScoutExtractResults(version: 1, generatedAt: "2026-07-16T00:00:00Z",
                                results: [ScoutExtractResult(sourceId: "org", verdict: .incompleteExtraction,
                                                             events: [event("A Show")],
                                                             note: "This page is larger than one Read call covered.")]),
            clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)

        #expect(s.notes == "This page is larger than one Read call covered.")
    }

    // MARK: - A page that came back correct and EMPTY

    // A quiet off-season is the NORMAL state (5 of the 7 spike sites, in July). It is not a failure, the
    // source is healthy, and its hash IS stamped: we read that page, and what it said was "nothing until
    // autumn". Re-reading it every day until the season starts would be paying to be told that again.
    @Test func aQuietOffSeasonIsHealthyAndItsHashIsStamped() throws {
        let ctx = try context()
        let s = queuedSource(ctx, pending: "new-hash", lastIngested: "old-hash")

        let outcome = ingest(results("org", verdict: .allPast), into: ctx)

        #expect(s.health == .ok)
        #expect(s.lastFailure == nil)
        #expect(s.lastContentHash == "new-hash")   // we DID read it. It just had nothing on.
        #expect(s.hasUnreadChanges == false)
        #expect(outcome.failedSources.isEmpty)
    }

    // An empty upcomingListings verdict is the same fact, arrived at differently, and is equally not a
    // failure.
    @Test func anEmptyButHealthyListingIsNotAFailure() throws {
        let ctx = try context()
        let s = queuedSource(ctx)

        ingest(results("org", verdict: .upcomingListings, events: []), into: ctx)

        #expect(s.health == .ok)
        #expect(s.lastContentHash == "new-hash")
    }

    // MARK: - The mismatches that must read as absence, never as the wrong show

    // A source id the app never queued resolves to nothing at all. The results file is written by a
    // Claude run: if it ever rebuilt an id instead of echoing it, the work must vanish loudly rather
    // than land on some other org's row.
    @Test func aSourceIdWeNeverQueuedIsIgnoredRatherThanGuessedAt() throws {
        let ctx = try context()
        let s = queuedSource(ctx, id: "org")

        let outcome = ingest(results("some-other-id", verdict: .upcomingListings,
                                     events: [event("Not Ours")]), into: ctx)

        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)
        #expect(outcome.inserted == 0)
        #expect(s.lastContentHash == "old-hash")   // our source is untouched
        #expect(s.hasUnreadChanges)                // and still waiting to be read

        // #857: and it vanishes LOUDLY, not silently. A result for an id we never queued means the run
        // rebuilt a key, so it is recorded and surfaced rather than dropped with no trace.
        #expect(outcome.unqueuedResultIds == ["some-other-id"])
        #expect(outcome.warning?.contains("some-other-id") == true)
    }

    // A source that was queued but that the run never got to (it died at source nine) keeps its pending
    // hash and its unread flag, so the next run picks it up again rather than skipping it forever.
    @Test func aSourceTheRunNeverReachedIsLeftPendingForNextTime() throws {
        let ctx = try context()
        let a = queuedSource(ctx, id: "a")
        let b = queuedSource(ctx, id: "b")

        // The run died after source a: only a is in the results.
        ingest(results("a", verdict: .upcomingListings, events: [event("A Show")]), into: ctx)

        #expect(a.lastContentHash == "new-hash")   // a landed
        #expect(b.lastContentHash == "old-hash")   // b did not, and is not pretended to have
        #expect(b.pendingContentHash == "new-hash")
        #expect(b.hasUnreadChanges)
    }

    // MARK: - The pipeline is the same one, so the same protections apply

    // A hand-added lead and a watched source both go through ScoutService.apply, which is what makes the
    // #769 do-not-contact suppression, the blocked-date skip and the #798 upcoming-only guard apply to a
    // watched source exactly as they do to everything else. A watchlist that could smuggle a refused org
    // back in would be worse than no watchlist.
    @Test func aPastDatedShowFromAWatchedSourceIsNeverImported() throws {
        let ctx = try context()
        queuedSource(ctx)

        let outcome = ingest(results("org", verdict: .upcomingListings,
                                     events: [event("Already Happened", date: "2020-01-01")]), into: ctx)

        #expect(outcome.inserted == 0)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)
    }

    // MARK: - #857: a run whose results disagree with themselves is not trusted

    // The run said every listing was in the past, then returned an upcoming show anyway. Today those
    // events were INGESTED off a verdict that claims there was nothing upcoming to ingest. A run that
    // disagrees with itself does not get to add shows.
    @Test func allPastWithEventsIsAContradictionAndDoesNotIngest() throws {
        let ctx = try context()
        let s = queuedSource(ctx)

        let outcome = ingest(results("org", verdict: .allPast, events: [event("A Show")]), into: ctx)

        #expect(s.health == .failing)
        guard case .inconsistentResult = s.lastFailure else {
            Issue.record("expected inconsistentResult, got \(String(describing: s.lastFailure))"); return
        }
        #expect(outcome.inserted == 0)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)   // NOT ingested
    }

    // A verdict that already fails on its own (no dated content) is RELABELLED as a contradiction when it
    // still returns events, so the reason Dan reads names the real problem (the run disagreed with
    // itself) rather than the generic "wrong page".
    @Test func noDatedContentWithEventsIsNamedAsAContradiction() throws {
        let ctx = try context()
        let s = queuedSource(ctx)

        ingest(results("org", verdict: .noDatedContent, events: [event("A Show")]), into: ctx)

        guard case .inconsistentResult = s.lastFailure else {
            Issue.record("expected inconsistentResult, got \(String(describing: s.lastFailure))"); return
        }
        #expect(s.runNote?.contains("no dated listings") == true)
    }

    // A consistent healthy read is untouched: the audit must never fail a source that agreed with itself.
    @Test func aConsistentReadStillLandsNormally() throws {
        let ctx = try context()
        let s = queuedSource(ctx)

        ingest(results("org", verdict: .upcomingListings, events: [event("A Show")]), into: ctx)

        #expect(s.health == .ok)
        #expect(s.lastFailure == nil)
    }
}
